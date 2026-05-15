# run.ps1  (cmi-outbound)
param(
    $Request,
    $TriggerMetadata
)

$ErrorActionPreference = 'Stop'

# ── tiny helpers ──────────────────────────────────────────────────────────────
function LogInfo($msg) { Write-Host ("[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg) }
function TextOK($s)   { @{ statusCode = [System.Net.HttpStatusCode]::OK;                  headers = @{ "Content-Type" = "text/plain" }; body = $s } }
function BadReq($s)   { @{ statusCode = [System.Net.HttpStatusCode]::BadRequest;          headers = @{ "Content-Type" = "text/plain" }; body = $s } }
function IntErr($s)   { @{ statusCode = [System.Net.HttpStatusCode]::InternalServerError; headers = @{ "Content-Type" = "text/plain" }; body = $s } }

# ---------------------------
# Helper: normalize JSON keys/boolean strings
# ---------------------------
function Normalize-JsonPropertyName {
    param([Parameter(Mandatory)][string]$Name)

    return $Name.Replace(' ', '').Replace('-', '')
}

function Normalize-JsonValue {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [string]) {
        if ($Value -ieq 'true') {
            return $true
        }

        if ($Value -ieq 'false') {
            return $false
        }

        return $Value
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $normalized = [ordered]@{}

        foreach ($key in $Value.Keys) {
            $normalizedName = Normalize-JsonPropertyName -Name ([string]$key)

            if ($normalized.Contains($normalizedName)) {
                throw "Property name collision after normalization: '$key' became '$normalizedName'."
            }

            $normalized[$normalizedName] = Normalize-JsonValue -Value $Value[$key]
        }

        return [pscustomobject]$normalized
    }

    if ($Value -is [pscustomobject]) {
        $normalized = [ordered]@{}

        foreach ($property in $Value.PSObject.Properties) {
            $normalizedName = Normalize-JsonPropertyName -Name $property.Name

            if ($normalized.Contains($normalizedName)) {
                throw "Property name collision after normalization: '$($property.Name)' became '$normalizedName'."
            }

            $normalized[$normalizedName] = Normalize-JsonValue -Value $property.Value
        }

        return [pscustomobject]$normalized
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $normalizedItems = [System.Collections.Generic.List[object]]::new()

        foreach ($item in $Value) {
            $normalizedItems.Add((Normalize-JsonValue -Value $item))
        }

        return ,$normalizedItems.ToArray()
    }

    return $Value
}

# ---------------------------
# Helper: invoke REST ignoring TLS cert (-k equivalent)
# ---------------------------
function Invoke-RestMethodInsecure {
    param(
        [Parameter(Mandatory)][ValidateSet('GET','POST','PUT','PATCH','DELETE')]
        [string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [hashtable]$Headers,
        [string]$ContentType,
        [string]$Body
    )

    $irm = Get-Command Invoke-RestMethod -ErrorAction Stop
    $hasSkip = $irm.Parameters.ContainsKey('SkipCertificateCheck')

    $params = @{
        Method      = $Method
        Uri         = $Uri
        Headers     = $Headers
        ContentType = $ContentType
        Body        = $Body
        ErrorAction = 'Stop'
    }

    if ($hasSkip) { $params['SkipCertificateCheck'] = $true }

    return Invoke-RestMethod @params
}

# ---------------------------
# Helper: basic reachability hints (won't guarantee routing)
# ---------------------------
function Test-TcpPort {
    param(
        [Parameter(Mandatory)][string]$HostOrIp,
        [int]$Port = 443,
        [int]$TimeoutMs = 3000
    )

    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $iar = $client.BeginConnect($HostOrIp, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            $client.Close()
            return $false
        }
        $client.EndConnect($iar)
        $client.Close()
        return $true
    }
    catch {
        return $false
    }
}

# ── short-circuit anything that's not POST ────────────────────────────────────
if ($Request.Method -ne 'POST') {
    Push-OutputBinding -Name Response -Value (TextOK "Howdy! POST JSON with { topicKey, ... } to route to Service Bus (and send to IB).")
    return
}

# ── parse JSON body ───────────────────────────────────────────────────────────
$raw = $null
$body = $null
try {
    $raw = if ($null -ne $Request.RawBody) { $Request.RawBody } else { $Request.Body }
    if ([string]::IsNullOrWhiteSpace($raw)) { throw "Empty request body." }
    $body = $raw | ConvertFrom-Json -ErrorAction Stop
    $body = Normalize-JsonValue -Value $body
}
catch {
    LogInfo "Failed to parse JSON from request body."
    LogInfo "Raw body:"
    LogInfo $raw
    Push-OutputBinding -Name Response -Value (BadReq "Invalid JSON body: $($_.Exception.Message)")
    return
}

# ── log + decide route ────────────────────────────────────────────────────────
LogInfo "INFORMATION: Parsed Body Content:"
LogInfo (($body | ConvertTo-Json -Depth 10))

$topicKey = [string]$body.topicKey
LogInfo "INFO: topicKey = '$topicKey'"

$routeStatus = 'ok'
$routeTarget = $null  # matter/client/payor or $null for "not routed"

# Serialize once for SB (if needed)
$jsonOut = ($body | ConvertTo-Json -Depth 10)

# ── route to service bus (NO FAILS) ───────────────────────────────────────────
try {
    switch ($topicKey) {
        'matter' {
            Push-OutputBinding -Name matter -Value $jsonOut
            $routeTarget = 'matter'
            $routeStatus = 'ok'
            LogInfo "Routed to matter"
        }
        'client' {
            Push-OutputBinding -Name client -Value $jsonOut
            $routeTarget = 'client'
            $routeStatus = 'ok'
            LogInfo "Routed to client"
        }
        'payor' {
            Push-OutputBinding -Name payor -Value $jsonOut
            $routeTarget = 'payor'
            $routeStatus = 'ok'
            LogInfo "Routed to payor"
        }
        default {
            # Do NOT publish to Service Bus
            $routeTarget = $null
            $routeStatus = 'error'
            LogInfo "No matching route for '$topicKey' -> NOT publishing to SB (status=error; IB will record)"
        }
    }
}
catch {
    Write-Error "Service Bus publish error: $_"
    Push-OutputBinding -Name Response -Value (IntErr "Service Bus publish failed: $($_.Exception.Message)")
    return
}

# =============================================================================
# SEND PAYLOAD TO INTEGRATION BUILDER RULE (ONCE) with status ok/error
# =============================================================================
try {
    $IbHost  = $env:intapp__ibHost
    $IbIp    = $env:intapp__ibIp
    $RuleId  = $env:intapp__ibRuleId
    $IbToken = $env:intapp__ibToken

    if (-not $IbHost)  { throw "Missing env:intapp__ibHost" }
    if (-not $RuleId)  { throw "Missing env:intapp__ibRuleId" }
    if (-not $IbToken) { throw "Missing env:intapp__ibToken" }

    $IbUrl = "https://$IbHost/api/v1/rules/$RuleId/execution?wait_for_completion=-1"
    LogInfo ("IB config: host={0} ip={1} ruleId={2}" -f $IbHost, ($IbIp ?? '[none]'), $RuleId)

    if ($IbIp) {
        if (Test-TcpPort -HostOrIp $IbIp -Port 443 -TimeoutMs 3000) {
            LogInfo "Preflight TCP check: $IbIp:443 is reachable (at least from here)."
        }
        else {
            LogInfo "WARN: Preflight TCP check: $IbIp:443 NOT reachable. If this is private, you likely need VNET integration/routing."
        }
    }
    else {
        LogInfo "INFO: Skipping TCP preflight (env:intapp__ibIp not set)."
    }

    $embedded = @"
{
  "timestamp": "$(Get-Date -Format o)",
  "status": "$routeStatus",
  "topicKey": "$topicKey",
  "routedTo": $(if ($routeTarget) { '"' + $routeTarget + '"' } else { 'null' }),
  "payload": $($body | ConvertTo-Json -Depth 50 -Compress)
}
"@

    LogInfo "IB jsonBody length (embedded): $($embedded.Length) chars"
    LogInfo "IB status sent: $routeStatus"

    # CHANGE: send RAW body to IB input instead of $embedded
    # This preserves the original JSON key order/format exactly as received.
    $ibRequest = @{
        inputs = @(
            @{
                name  = "jsonBody"
                value = [string]$raw
            }
        )
    } | ConvertTo-Json -Depth 10

    $headers = @{
        IntegrateAuthenticationToken = $IbToken
    }

    LogInfo "Calling Integration Builder rule: $IbUrl"
    $resp = Invoke-RestMethodInsecure -Method 'POST' -Uri $IbUrl -Headers $headers -ContentType 'application/json' -Body $ibRequest
}
catch {
    # fail-open: don't fail the HTTP call if IB fails
    LogInfo "ERROR: IB rule execution failed: $($_.Exception.Message)"
}

# ── success ───────────────────────────────────────────────────────────────────
if ($routeStatus -eq 'ok') {
    Push-OutputBinding -Name Response -Value (TextOK "Routed '$topicKey' to SB ($routeTarget) and sent to IB (status=ok)")
}
else {
    # Keeping 200 so callers don't retry forever; adjust to 400 if you want them to fix input.
    Push-OutputBinding -Name Response -Value (TextOK "No SB route for '$topicKey'. Sent to IB only (status=error).")
}

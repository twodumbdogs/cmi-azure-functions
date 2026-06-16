# run.ps1  (sb-responses-v1.6) - Service Bus Trigger
param(
    $msg,
    $TriggerMetadata
)

$ErrorActionPreference = 'Stop'
$__VERSION = 'sb-responses-v1.6'

# ── tiny helpers ──────────────────────────────────────────────────────────────
function LogInfo($m) { Write-Host ("[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m) }
function LogWarn($m) { Write-Host ("[{0}] WARN: {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m) }
function LogErr($m)  { Write-Host ("[{0}] ERROR: {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m) }

# Subscriber context (Service Bus Topic/Subscription)
$script:SubscriberId = 'unknown'
if ($TriggerMetadata) {
    if ($TriggerMetadata.Topic -and $TriggerMetadata.SubscriptionName) {
        $script:SubscriberId = "$($TriggerMetadata.Topic)/$($TriggerMetadata.SubscriptionName)"
    }
    elseif ($TriggerMetadata.Topic) {
        $script:SubscriberId = [string]$TriggerMetadata.Topic
    }
}

function LogCtx($m) {
    LogInfo "[sb-subscriber][$__VERSION][$script:SubscriberId] $m"
}

# ---------------------------
# Helper: resolve Function name (reliable across hosting variants)
# ---------------------------
function Get-FunctionName {
    param($TriggerMetadata)

    # 1) Trigger metadata (best when present)
    try {
        if ($TriggerMetadata) {
            if ($TriggerMetadata.FunctionName) { return [string]$TriggerMetadata.FunctionName }
            if ($TriggerMetadata.functionName) { return [string]$TriggerMetadata.functionName }

            if ($TriggerMetadata -is [hashtable]) {
                foreach ($k in @('FunctionName','functionName','AzureWebJobsFunctionName','FUNCTIONS_FUNCTION_NAME','FUNCTION_NAME')) {
                    if ($TriggerMetadata.ContainsKey($k) -and $TriggerMetadata[$k]) {
                        return [string]$TriggerMetadata[$k]
                    }
                }
            }
        }
    }
    catch { }

    # 2) Environment variables (varies by runtime/hosting)
    foreach ($k in @('AzureWebJobsFunctionName','FUNCTIONS_FUNCTION_NAME','FUNCTION_NAME')) {
        try {
            $v = [string](Get-Item -Path "Env:$k" -ErrorAction SilentlyContinue).Value
            if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
        }
        catch { }
    }

    # 3) Fallback: Function App name (better than unknown)
    if (-not [string]::IsNullOrWhiteSpace($env:WEBSITE_SITE_NAME)) {
        return [string]$env:WEBSITE_SITE_NAME
    }

    return 'unknown-function'
}

# ---------------------------
# TCP preflight check
# ---------------------------
function Test-TcpPort {
    param(
        [Parameter(Mandatory)][string]$HostOrIp,
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutMs = 3000
    )

    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $iar = $client.BeginConnect($HostOrIp, $Port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)

        if (-not $ok) {
            try { $client.Close() } catch {}
            return $false
        }

        $client.EndConnect($iar)
        $client.Close()
        return $true
    }
    catch {
        try { $client.Close() } catch {}
        return $false
    }
}

# ---------------------------
# Invoke REST ignoring TLS cert
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
# Determine message type
# ---------------------------
function Get-MessageType {
    param([string]$Topic)

    if ([string]::IsNullOrWhiteSpace($Topic)) { return "unknown" }

    $parts = $Topic.Split('.',4)
    if ($parts.Count -ge 2) { return $parts[1] }

    return "unknown"
}

# ---------------------------
# ENV / CONFIG
# ---------------------------
try {
    $IbHost  = $env:intapp__ibHost
    $IbIp    = $env:intapp__ibIp
    $RuleId  = $env:intapp__rule_id_regional_subscribe
    $IbToken = $env:intapp__ibToken

    if (-not $IbHost)  { throw "Missing env:intapp__ibHost" }
    if (-not $RuleId)  { throw "Missing env:intapp__rule_id_regional_subscribe" }
    if (-not $IbToken) { throw "Missing env:intapp__ibToken" }

    $RuleUrl = "https://$IbHost/api/v1/rules/$RuleId/execution?wait_for_completion=-1"

    $ipShown = if ($IbIp) { $IbIp } else { '[none]' }
    LogCtx ("IB config: host={0} ip={1} ruleId={2}" -f $IbHost, $ipShown, $RuleId)

    if ($IbIp) {
        if (Test-TcpPort -HostOrIp $IbIp -Port 443) {
            LogCtx "Preflight TCP check: $IbIp:443 reachable."
        }
        else {
            LogWarn "Preflight TCP check: $IbIp:443 NOT reachable."
        }
    }
}
catch {
    LogErr "IB configuration error: $($_.Exception.Message)"
    throw
}

# ---------------------------
# MAIN EXECUTION
# ---------------------------
try {
    if ($null -eq $msg) {
        LogCtx "Received null message — skipping."
        return
    }

    $raw = if ($msg -is [string]) { $msg } else { ($msg | ConvertTo-Json -Depth 50) }

    if ([string]::IsNullOrWhiteSpace($raw)) {
        LogCtx "Message empty after serialization — skipping."
        return
    }

    LogCtx "Received message. Size: $($raw.Length) bytes."

    $topic = if ($TriggerMetadata -and $TriggerMetadata.Topic) { [string]$TriggerMetadata.Topic } else { $null }

    # ✅ Use the FUNCTION NAME as region-subscription (robust resolver)
    $functionName = Get-FunctionName -TriggerMetadata $TriggerMetadata
    LogCtx ("Function name resolved as: {0} (EnvHints: AzureWebJobsFunctionName='{1}' FUNCTIONS_FUNCTION_NAME='{2}' WEBSITE_SITE_NAME='{3}')" -f `
        $functionName, $env:AzureWebJobsFunctionName, $env:FUNCTIONS_FUNCTION_NAME, $env:WEBSITE_SITE_NAME)

    $msgType = Get-MessageType -Topic $topic
    $receivedUtc = (Get-Date).ToUniversalTime().ToString("o")

    # -------------------------------------------------
    # Build IB inputs (REGION PREFIXED)
    # -------------------------------------------------
    $inputs = @(
        @{ name="region-body";         value=[string]$raw }
        @{ name="region-topic";        value=[string]$topic }
        @{ name="region-subscription"; value=[string]$functionName }   # 👈 function name now
        @{ name="region-subscriberId"; value=[string]$script:SubscriberId }
        @{ name="region-messageType";  value=[string]$msgType }
        @{ name="region-receivedUtc";  value=[string]$receivedUtc }
    )

    $ibRequest = @{ inputs = $inputs } | ConvertTo-Json -Depth 10
    LogCtx "IB request built with $($inputs.Count) region inputs. region-subscription=$functionName"

    $headers = @{
        accept = "application/xml"
        IntegrateAuthenticationToken = $IbToken
    }

    $response = Invoke-RestMethodInsecure `
        -Method POST `
        -Uri $RuleUrl `
        -Headers $headers `
        -ContentType "application/json" `
        -Body $ibRequest

    LogCtx "Rule execution triggered successfully."
}
catch {
    LogErr "Unhandled error: $($_.Exception.Message)"
    LogErr ($_ | Out-String)

    try {
        Push-OutputBinding -Name fails -Value $msg
        LogWarn "Moved failed message to 'fails' topic."
    }
    catch {
        LogErr "Could not route to fails topic: $($_.Exception.Message)"
    }

    throw
}
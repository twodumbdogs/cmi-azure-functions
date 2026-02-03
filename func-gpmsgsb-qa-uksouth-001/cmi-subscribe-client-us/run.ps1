# run.ps1
param($msg, $TriggerMetadata)

$ErrorActionPreference = 'Stop'
$__VERSION = 'sb-responses-v1.6-ib-rule'

# ---------------------------
# LOGGING WITH SUBSCRIBER CONTEXT
# ---------------------------
if ($TriggerMetadata) {
    $script:SubscriberId = if ($TriggerMetadata.Topic -and $TriggerMetadata.SubscriptionName) {
        "$($TriggerMetadata.Topic)/$($TriggerMetadata.SubscriptionName)"
    }
    elseif ($TriggerMetadata.Topic) {
        $TriggerMetadata.Topic
    }
    else {
        'unknown'
    }
}
else {
    $script:SubscriberId = 'unknown'
}

function Write-Log {
    param(
        [ValidateSet('INFO','WARN','ERROR')]
        [string]$Level = 'INFO',
        [Parameter(Mandatory)][string]$Message
    )
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fffK')
    Write-Host "[$ts][$Level][sb-subscriber][$__VERSION][$script:SubscriberId] $Message"
}

# ---------------------------
# ENV CONFIG (Integration Builder)
# ---------------------------
# REQUIRED: host used in URL (keeps SNI/Host header clean)
# Examples:
#   auk3vdwkfinb01
#   auk3vdwkfinb01.ad.adsinternal.com
$IbHost  = $env:intapp__ibHost

# OPTIONAL: private IP for TCP reachability preflight
$IbIp    = $env:intapp__ibIp

# REQUIRED
$RuleId  = $env:intapp__ibRuleId
$IbToken = $env:intapp__ibToken

if (-not $IbHost)  { Write-Log -Level 'ERROR' -Message "Missing env:intapp__ibHost";   throw "Missing ibHost" }
if (-not $RuleId)  { Write-Log -Level 'ERROR' -Message "Missing env:intapp__ibRuleId"; throw "Missing ibRuleId" }
if (-not $IbToken) { Write-Log -Level 'ERROR' -Message "Missing env:intapp__ibToken";  throw "Missing ibToken" }

# matches your curl: wait_for_completion=-1
$IbUrl = "https://$IbHost/api/v1/rules/$RuleId/execution?wait_for_completion=-1"

Write-Log -Message ("IB config: host={0} ip={1} ruleId={2}" -f $IbHost, ($(if ($IbIp) { $IbIp } else { '[none]' })), $RuleId)

# ---------------------------
# DETERMINE TYPE (clients / matters / etc)
# ---------------------------
function Get-MessageType {
    param(
        [string]$Topic,
        $ParsedObject
    )

    # 1) Prefer payload hints if present
    if ($null -ne $ParsedObject) {
        foreach ($prop in @('type','Type','entityType','EntityType')) {
            if ($ParsedObject.PSObject.Properties.Name -contains $prop) {
                $val = [string]$ParsedObject.$prop
                if ($val) { return $val }
            }
        }
    }

    # 2) Fallback to topic parsing
    if ($Topic) {
        if ($Topic -eq 'cmi-fails') { return 'fails' }
        $parts = $Topic.Split('.', 4)  # e.g. compliance.clients.v1
        if ($parts.Count -ge 2) { return $parts[1] }
    }

    return "unknown"
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

    if ($hasSkip) {
        $params['SkipCertificateCheck'] = $true
    }
    else {
        Write-Log -Level 'WARN' -Message "Invoke-RestMethod has no -SkipCertificateCheck in this runtime; TLS validation may still occur."
    }

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

# ---------------------------
# MAIN EXECUTION
# ---------------------------
try {
    if (-not $msg) {
        Write-Log -Level 'WARN' -Message "Received an empty or null message — skipping."
        return
    }

    $raw  = if ($msg -is [string]) { $msg } else { $msg | ConvertTo-Json -Depth 50 }
    $size = $raw.Length
    Write-Log -Message "Received message. Size: $size bytes."

    $obj = $null
    try {
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-Log -Level 'WARN' -Message "Message not valid JSON — treating as plain text."
    }

    if ($obj) {
        $preview = @{}
        foreach ($k in @('EventType','RequestID','ClientId','MatterId','CorrelationId')) {
            if ($obj.PSObject.Properties.Name -contains $k) { $preview[$k] = $obj.$k }
        }
        $previewJson = ($preview | ConvertTo-Json -Depth 5)
        Write-Log -Message "Parsed JSON preview: $previewJson"
    }
    else {
        $textPreview = if ($raw.Length -gt 1000) { $raw.Substring(0,1000) + "..." } else { $raw }
        Write-Log -Message "Message text (preview): $textPreview"
    }

    $msgType = Get-MessageType -Topic $TriggerMetadata.Topic -ParsedObject $obj
    Write-Log -Message "Message type derived as: $msgType"

    # Optional TCP preflight (only if ibIp provided)
    if ($IbIp) {
        $tcpOk = Test-TcpPort -HostOrIp $IbIp -Port 443 -TimeoutMs 3000
        if ($tcpOk) {
            Write-Log -Message "Preflight TCP check: $IbIp:443 is reachable (at least from here)."
        }
        else {
            Write-Log -Level 'WARN' -Message "Preflight TCP check: $IbIp:443 NOT reachable. If this is private, you likely need VNET integration/routing."
        }
    }
    else {
        Write-Log -Level 'INFO' -Message "Skipping TCP preflight (env:intapp__ibIp not set)."
    }

    # Build IB embedded jsonBody string (metadata + payload)
    $topicName = $null
    try { $topicName = $TriggerMetadata.Topic } catch { $topicName = $null }

    $embedded = @{
        timestamp   = (Get-Date).ToString("o")
        messageType = $msgType
        topic       = $(if ($topicName) { $topicName } else { 'unknown' })
        subscriber  = $script:SubscriberId
        payload     = $(if ($obj) { $obj } else { $raw })
    } | ConvertTo-Json -Depth 50 -Compress

    Write-Log -Message "IB jsonBody length: $($embedded.Length) chars"

    # Build IB request wrapper
    $ibRequest = @{
        inputs = @(
            @{
                name  = "jsonBody"
                value = $embedded
            }
        )
    } | ConvertTo-Json -Depth 10 -Compress

    $headers = @{
        IntegrateAuthenticationToken = $IbToken
        accept = "application/json"
    }

    Write-Log -Message "Calling Integration Builder rule: $IbUrl"

    try {
        $resp = Invoke-RestMethodInsecure -Method 'POST' -Uri $IbUrl -Headers $headers -ContentType 'application/json' -Body $ibRequest

        $respText = $null
        try { $respText = ($resp | Out-String).Trim() } catch { $respText = "[unprintable response]" }

        if ($respText) {
            if ($respText.Length -gt 2000) { $respText = $respText.Substring(0,2000) + "..." }
            Write-Log -Message "IB response (truncated): $respText"
        }
        else {
            Write-Log -Message "IB response received (empty body)."
        }
    }
    catch {
        # Try to capture any response body (useful for XML/HTML error responses)
        $body = $null
        try {
            $respObj = $_.Exception.Response
            if ($respObj) {
                # Works best when Invoke-RestMethod is backed by HttpClient in PS 7+
                if ($respObj.Content) {
                    $body = $respObj.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                }
                else {
                    # Fallback for WebResponse
                    $stream = $respObj.GetResponseStream()
                    if ($stream) {
                        $reader = [System.IO.StreamReader]::new($stream)
                        $body = $reader.ReadToEnd()
                        $reader.Close()
                        $stream.Close()
                    }
                }
            }
        } catch { }

        if ($body) {
            if ($body.Length -gt 2000) { $body = $body.Substring(0,2000) + "..." }
            Write-Log -Level 'ERROR' -Message "IB rule execution failed: $($_.Exception.Message) Body: $body"
        }
        else {
            Write-Log -Level 'ERROR' -Message "IB rule execution failed: $($_.Exception.Message)"
        }

        throw
    }

    Write-Log -Message "Processed OK ✅"
}
catch {
    Write-Log -Level 'ERROR' -Message "Unhandled error: $($_.Exception.Message)`n$($_ | Out-String)"
    throw
}

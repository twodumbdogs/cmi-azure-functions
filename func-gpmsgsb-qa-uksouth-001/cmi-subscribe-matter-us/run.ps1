# run.ps1  (sb-responses-v1.6) - Service Bus Trigger
param(
    $msg,
    $TriggerMetadata
)

$ErrorActionPreference = 'Stop'
$__VERSION = 'sb-responses-v1.6'

# ── tiny helpers ──────────────────────────────────────────────────────────────
function LogInfo($m)  { Write-Host ("[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m) }
function LogWarn($m)  { Write-Host ("[{0}] WARN: {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m) }
function LogErr($m)   { Write-Host ("[{0}] ERROR: {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m) }

# Keep your "subscriber context" concept, just logged in the same style
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
# DETERMINE TYPE (clients / matters / etc)
# ---------------------------
function Get-MessageType {
    param([string]$Topic)

    if ([string]::IsNullOrWhiteSpace($Topic)) { return "unknown" }

    # Topic format example: "compliance.clients.v1"
    $parts = $Topic.Split('.', 4)
    if ($parts.Count -ge 2) { return $parts[1] }

    return "unknown"
}

# ---------------------------
# ENV / CONFIG  (unchanged)
# ---------------------------

# Auth code for Integrate rule execution
$ibauthcode = $env:ibauthcode
if (-not $ibauthcode) {
    LogCtx "Missing env:ibauthcode (IntegrateAuthenticationToken)."
    throw "Missing ibauthcode"
}

# Rule execution endpoint (unchanged)
$RuleHost = $env:intapp__ibHost
$RuleId   = $env:intapp_rule_id_regional_subscribe
$RuleUrl  = "https://$RuleHost/api/v1/rules/$RuleId/execution?wait_for_completion=-1"

# ---------------------------
# MAIN EXECUTION
# ---------------------------
try {
    if ($null -eq $msg) {
        LogCtx "Received an empty/null message — skipping."
        return
    }

    # Serialize once (same concept as your http-trigger function)
    $raw = if ($msg -is [string]) { [string]$msg } else { ($msg | ConvertTo-Json -Depth 50) }
    if ([string]::IsNullOrWhiteSpace($raw)) {
        LogCtx "Message was effectively empty after serialization — skipping."
        return
    }

    LogCtx "Received message. Size: $($raw.Length) bytes."

    # Parse JSON if possible, but don't die if it isn't JSON
    $obj = $null
    try {
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        LogCtx "Parsed JSON successfully."
    }
    catch {
        LogWarn "[sb-subscriber][$__VERSION][$script:SubscriberId] Message not valid JSON — treating as plain text."
    }

    if ($obj) {
        # Keep your preview idea, just keep it resilient
        $preview = @{
            eventType = $obj.EventType
            requestId = $obj.RequestID
            clientId  = $obj.ClientId
        } | ConvertTo-Json -Depth 5

        LogCtx "Parsed JSON preview: $preview"
    }
    else {
        $textPreview = $raw
        if ($textPreview.Length -gt 800) { $textPreview = $textPreview.Substring(0,800) + "..." }
        LogCtx "Message text preview: $textPreview"
    }

    $topic = $null
    if ($TriggerMetadata -and $TriggerMetadata.Topic) { $topic = [string]$TriggerMetadata.Topic }

    $msgType = Get-MessageType -Topic $topic
    LogCtx "Message type derived as: $msgType"

    # -------------------------------------------------
    # EXECUTE INTEGRATE RULE (curl -k equivalent)
    # (UNCHANGED endpoint/headers/body/params)
    # -------------------------------------------------
    LogCtx "Triggering Integrate rule execution: RuleId=$RuleId Host=$RuleHost wait_for_completion=-1 (TLS validate: OFF)"

    $headers = @{
        accept = "application/xml"
        IntegrateAuthenticationToken = $ibauthcode
    }

    # KEEP SAME BODY BEHAVIOR (empty JSON object)
    $body = @{} | ConvertTo-Json

    $response = Invoke-RestMethodInsecure -Method 'POST' -Uri $RuleUrl -Headers $headers -ContentType "application/json" -Body $body

    LogCtx "Rule execution triggered successfully."

    if ($response) {
        $respPreview = ($response | Out-String).Trim()
        if ($respPreview.Length -gt 800) { $respPreview = $respPreview.Substring(0,800) + "..." }
        LogCtx "Rule API response (preview): $respPreview"
    }

    LogCtx "Processed OK ✅"
}
catch {
    LogErr "[sb-subscriber][$__VERSION][$script:SubscriberId] Unhandled error: $($_.Exception.Message)"
    LogErr "[sb-subscriber][$__VERSION][$script:SubscriberId] $($_ | Out-String)"

    # Keep your existing behavior: try to move the original message to fails, if that binding exists
    try {
        Push-OutputBinding -Name fails -Value $msg
        LogWarn "[sb-subscriber][$__VERSION][$script:SubscriberId] Moved failed message to 'fails' topic."
    }
    catch {
        LogErr "[sb-subscriber][$__VERSION][$script:SubscriberId] Could not route to fails topic: $($_.Exception.Message)"
    }

    throw
}
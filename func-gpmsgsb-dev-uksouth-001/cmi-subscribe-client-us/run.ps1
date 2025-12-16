# run.ps1

param($msg, $TriggerMetadata)

$ErrorActionPreference = 'Stop'
$__VERSION = 'sb-responses-v1.6'

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
# ENV / CONFIG
# ---------------------------

# Auth code for Integrate rule execution
$ibauthcode = $env:ibauthcode

if (-not $ibauthcode) {
    Write-Log -Level 'ERROR' -Message "Missing env:ibauthcode (IntegrateAuthenticationToken)."
    throw "Missing ibauthcode"
}

# Rule execution endpoint
$RuleHost = "auk3vdwkfinb01"
$RuleId   = 1027
$RuleUrl  = "https://$RuleHost/api/v1/rules/$RuleId/execution?wait_for_completion=-1"

# ---------------------------
# DETERMINE TYPE (clients / matters / etc)
# ---------------------------

function Get-MessageType {
    param([string]$Topic)

    if (-not $Topic) { return "unknown" }

    # Topic format example: "compliance.clients.v1"
    $parts = $Topic.Split('.', 4)

    if ($parts.Count -ge 2) {
        return $parts[1]   # clients, matters, etc.
    }

    return "unknown"
}

# ---------------------------
# INVOKE-RM WITH "curl -k" BEHAVIOR
# ---------------------------

function Invoke-RestMethodK {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Method,
        [hashtable]$Headers,
        [string]$ContentType,
        [string]$Body
    )

    # Preferred path: PowerShell 7+ native support
    $irm = Get-Command Invoke-RestMethod -ErrorAction Stop
    $hasSkip = $irm.Parameters.ContainsKey('SkipCertificateCheck')

    if ($hasSkip) {
        return Invoke-RestMethod -Method $Method -Uri $Uri `
            -Headers $Headers `
            -ContentType $ContentType `
            -Body $Body `
            -SkipCertificateCheck
    }

    # Fallback path: last-resort global callback (works for HttpWebRequest scenarios)
    # NOTE: In some PS/NET combos this may not affect HttpClient. It's a best-effort fallback.
    Write-Log -Level 'WARN' -Message "Invoke-RestMethod has no -SkipCertificateCheck in this runtime; using global cert bypass fallback."

    $prev = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
    try {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }

        return Invoke-RestMethod -Method $Method -Uri $Uri `
            -Headers $Headers `
            -ContentType $ContentType `
            -Body $Body
    }
    finally {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $prev
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
        $preview = @{
            eventType = $obj.EventType
            requestId = $obj.RequestID
            clientId  = $obj.ClientId
        } | ConvertTo-Json -Depth 5
        Write-Log -Message "Parsed JSON preview: $preview"
    }
    else {
        Write-Log -Message "Message text: $raw"
    }

    $msgType = Get-MessageType -Topic $TriggerMetadata.Topic
    Write-Log -Message "Message type derived as: $msgType"

    # -------------------------------------------------
    # EXECUTE INTEGRATE RULE (curl -k equivalent)
    # -------------------------------------------------

    Write-Log -Message "Triggering Integrate rule execution: RuleId=$RuleId Host=$RuleHost wait_for_completion=-1 (TLS validate: OFF)"

    $headers = @{
        accept = "application/xml"
        IntegrateAuthenticationToken = $ibauthcode
    }

    # Put the SB message JSON/text into the Integrate input as a STRING.
    # ConvertTo-Json will escape quotes/newlines etc so the outer JSON stays valid.
    $bodyObject = @{
        inputs = @(
            @{
                name  = "jsonBody"
                value = $raw
            }
        )
    }

    $body = $bodyObject | ConvertTo-Json -Depth 10 -Compress

    # Optional: log a tiny body preview, not the whole thing (avoid noisy logs)
    $bodyPreview = if ($body.Length -gt 500) { $body.Substring(0,500) + "..." } else { $body }
    Write-Log -Message "Integrate POST body preview: $bodyPreview"

    try {
        $response = Invoke-RestMethodK -Method 'Post' -Uri $RuleUrl `
            -Headers $headers `
            -ContentType "application/json" `
            -Body $body

        Write-Log -Message "Rule execution triggered successfully."

        if ($response) {
            $respPreview = ($response | Out-String).Trim()
            if ($respPreview.Length -gt 800) { $respPreview = $respPreview.Substring(0,800) + "..." }
            Write-Log -Message "Rule API response (preview): $respPreview"
        }
    }
    catch {
        Write-Log -Level 'ERROR' -Message "Rule execution call failed: $($_.Exception.Message)"
        throw
    }

    Write-Log -Message "Processed OK ✅"
}
catch {
    Write-Log -Level 'ERROR' -Message "Unhandled error: $($_.Exception.Message)`n$($_ | Out-String)"

    try {
        Push-OutputBinding -Name fails -Value $msg
        Write-Log -Level 'WARN' -Message "Moved failed message to 'fails' topic."
    }
    catch {
        Write-Log -Level 'ERROR' -Message "Could not route to fails topic: $($_.Exception.Message)"
    }

    throw
}

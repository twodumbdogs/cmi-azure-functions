# run.ps1

param($msg, $TriggerMetadata)

$ErrorActionPreference = 'Stop'
$__VERSION = 'sb-responses-v1.4'

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
# ENV CONFIG
# ---------------------------

$ClientId     = $env:intapp__clientId
$ClientSecret = $env:intapp__clientSecret
$TokenUrl     = $env:intapp__tokenUrl
$ApiHost      = $env:intapp__apiHost

if (-not $ApiHost) {
    Write-Log -Level 'ERROR' -Message "No API host defined in env:intapp__apiHost"
    throw "Missing API Host"
}

$ApiUrl = "https://$ApiHost/Open.Services.REST/api/common/v1/virtualtables/sb-responses"

# ---------------------------
# TOKEN HELPER
# ---------------------------

function Get-IntappToken {
    Write-Log -Message "Requesting token from $TokenUrl"

    $body = @{
        grant_type    = "client_credentials"
        client_id     = $ClientId
        client_secret = $ClientSecret
    }

    try {
        $response = Invoke-RestMethod -Method Post -Uri $TokenUrl `
            -ContentType "application/x-www-form-urlencoded" `
            -Body $body

        if ($response.access_token) {
            Write-Log -Message "Successfully acquired access token."
            return $response.access_token
        }

        Write-Log -Level 'ERROR' -Message "Token response missing access_token."
        throw "No access_token field"
    }
    catch {
        Write-Log -Level 'ERROR' -Message "Token request failed: $($_.Exception.Message)"
        throw
    }
}

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
# MAIN EXECUTION
# ---------------------------

try {
    if (-not $msg) {
        Write-Log -Level 'WARN' -Message "Received an empty or null message — skipping."
        return
    }

    $raw = if ($msg -is [string]) { $msg } else { $msg | ConvertTo-Json -Depth 50 }
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

    # ---------------------------------------------
    # Determine the TYPE (clients/matters/etc)
    # ---------------------------------------------
    $msgType = Get-MessageType -Topic $TriggerMetadata.Topic
    Write-Log -Message "Message type derived as: $msgType"

    # -------------------------------------------------
    # SEND TO INTAPP API
    # -------------------------------------------------

    $token = Get-IntappToken

    $payload = @(
        @{
            timestamp = (Get-Date).ToString("o")
            type      = $msgType   # <-- NEW FIELD ADDED HERE
            payload   = $obj
            status    = "ok"
        }
    ) | ConvertTo-Json -Depth 20

    Write-Log -Message "Sending payload to API: $ApiUrl"

    try {
        $response = Invoke-RestMethod -Method Put -Uri $ApiUrl `
            -Headers @{ Authorization = "Bearer $token" } `
            -ContentType "application/json" `
            -Body $payload

        Write-Log -Message "API response received successfully."
    }
    catch {
        Write-Log -Level 'ERROR' -Message "API call failed: $($_.Exception.Message)"
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

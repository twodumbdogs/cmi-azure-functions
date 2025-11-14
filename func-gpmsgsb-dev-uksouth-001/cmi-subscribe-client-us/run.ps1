# subscribe to US clients
param($msg, $TriggerMetadata)

$ErrorActionPreference = 'Stop'
$__VERSION = 'clients-v1.2'

Write-Host "[SB] Polling $($TriggerMetadata.Topic) / $($TriggerMetadata.SubscriptionName) from $env:us_sb__fullyQualifiedNamespace"

function Write-Log {
    param(
        [ValidateSet('INFO','WARN','ERROR')]
        [string]$Level = 'INFO',
        [Parameter(Mandatory)][string]$Message
    )
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fffK')
    Write-Host "[$ts][$Level][clients-subscriber][$__VERSION] $Message"
}

# ---------------------------
# ENV CONFIG
# ---------------------------

$ClientId     = $env:intapp__clientId
$ClientSecret = $env:intapp__clientSecret
$TokenUrl     = $env:intapp__tokenUrl
$ApiHost      = $env:intapp__apiHost   # e.g. suk3vdwkfweb01.ad.adsinternal.com

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
# MAIN EXECUTION
# ---------------------------
try {
    if (-not $msg) {
        Write-Log -Level 'WARN' -Message "Received an empty or null message — skipping."
        return
    }

    # Normalize body
    $raw = if ($msg -is [string]) { $msg } else { $msg | ConvertTo-Json -Depth 50 }
    $size = $raw.Length
    Write-Log -Message "Received message. Size: $size bytes."

    # JSON parse attempt
    $obj = $null
    try {
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Log -Level 'WARN' -Message "Message not valid JSON — treating as plain text."
    }

    if ($obj) {
        $preview = @{
            eventType = $obj.EventType
            requestId = $obj.RequestID
            clientId  = $obj.ClientId
        } | ConvertTo-Json -Depth 5
        Write-Log -Message "Parsed JSON preview: $preview"
    } else {
        Write-Log -Message "Message text: $raw"
    }

    # -------------------------------------------------
    # SEND MESSAGE TO INTAPP API
    # -------------------------------------------------

    $token = Get-IntappToken

    $payload = @(
        @{
            timestamp = (Get-Date).ToString("o")
            payload   = $obj       # raw JSON object from SB
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

    # Marks success
    Write-Log -Message "Processed OK ✅"
}
catch {
    Write-Log -Level 'ERROR' -Message "Unhandled error: $($_.Exception.Message)`n$($_ | Out-String)"

    try {
        Push-OutputBinding -Name fails -Value $msg
        Write-Log -Level 'WARN' -Message "Routed failed message to 'fails' topic."
    } catch {
        Write-Log -Level 'ERROR' -Message "Could not route to fails topic: $($_.Exception.Message)"
    }

    throw
} 

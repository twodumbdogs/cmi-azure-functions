# subscribe to US clients
param($msg, $TriggerMetadata)

$ErrorActionPreference = 'Stop'
$__VERSION = 'clients-v1.1'

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

try {
    # Guard against null message
    if (-not $msg) {
        Write-Log -Level 'WARN' -Message "Received an empty or null message — skipping."
        return
    }

    # Normalize body
    $raw = if ($msg -is [string]) { $msg } else { $msg | ConvertTo-Json -Depth 50 }
    $size = if ($null -ne $raw) { $raw.Length } else { 0 }
    Write-Log -Message "Received message. Size: $size bytes."

    # Try parse JSON
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

    # Forward the message to your UK SB topic
    Push-OutputBinding -Name forward -Value $raw
    Write-Log -Message "Forwarded to UK Service Bus topic (connection: 'uk_sb')."

    # Mark success
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

#run.ps1

param(
    $Request,
    $TriggerMetadata
)

$ErrorActionPreference = 'Stop'

# ── tiny helpers ──────────────────────────────────────────────────────────────
function LogInfo($msg) { Write-Host ("[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg) }
function TextOK($s)   { @{ statusCode = [System.Net.HttpStatusCode]::OK;                 headers = @{ "Content-Type" = "text/plain"    }; body = $s } }
function BadReq($s)   { @{ statusCode = [System.Net.HttpStatusCode]::BadRequest;         headers = @{ "Content-Type" = "text/plain"    }; body = $s } }
function IntErr($s)   { @{ statusCode = [System.Net.HttpStatusCode]::InternalServerError; headers = @{ "Content-Type" = "text/plain"    }; body = $s } }

# ── short-circuit anything that's not POST ────────────────────────────────────
if ($Request.Method -ne 'POST') {
    Push-OutputBinding -Name Response -Value (TextOK "Howdy! POST JSON with { topicKey, ... } to route to Service Bus.")
    return
}

# ── parse JSON body ───────────────────────────────────────────────────────────
try {
    $raw = if ($null -ne $Request.RawBody) { $Request.RawBody } else { $Request.Body }
    if ([string]::IsNullOrWhiteSpace($raw)) { throw "Empty request body." }
    $body = $raw | ConvertFrom-Json
}
catch {
    LogInfo "Failed to parse JSON from request body."
    LogInfo "Raw body:"
    LogInfo $raw
    Push-OutputBinding -Name Response -Value (BadReq "Invalid JSON body: $($_.Exception.Message)")
    return
}

# ── log + route ───────────────────────────────────────────────────────────────
LogInfo "INFORMATION: Parsed Body Content:"
LogInfo (($body | ConvertTo-Json -Depth 10))

$topicKey = $body.topicKey
LogInfo "INFO: topicKey = '$topicKey'"

try {
    $jsonOut = ($body | ConvertTo-Json -Depth 10)

    switch ($topicKey) {
        'matter' {
            Push-OutputBinding -Name matter -Value $jsonOut
            LogInfo "Routed to matter"
        }
        'client' {
            Push-OutputBinding -Name client -Value $jsonOut
            LogInfo "Routed to client"
        }
        'payor' {
            Push-OutputBinding -Name payor -Value $jsonOut
            LogInfo "Routed to payor"
        }
        default {
            LogInfo "No matching route for '$topicKey'; sending message to error queue"
            Push-OutputBinding -Name fails -Value $jsonOut
        }
    }
}
catch {
    Write-Error "Service Bus publish error: $_"
    Push-OutputBinding -Name Response -Value (IntErr "Service Bus publish failed: $($_.Exception.Message)")
    return
}

# ── success ───────────────────────────────────────────────────────────────────
Push-OutputBinding -Name Response -Value (TextOK "Successfully routed '$topicKey'")

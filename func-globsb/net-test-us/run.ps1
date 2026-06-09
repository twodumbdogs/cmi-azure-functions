param($Request, $TriggerMetadata)

$ErrorActionPreference = 'Stop'
$__VERSION = 'net-test-v1.0'

function Write-Log {
    param(
        [ValidateSet('INFO','WARN','ERROR')]
        [string]$Level = 'INFO',
        [Parameter(Mandatory)][string]$Message
    )
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fffK')
    Write-Host "[$ts][$Level][net-test][$__VERSION] $Message"
}

try {
    $sbHost = $env:us_sb__fullyQualifiedNamespace
    if ([string]::IsNullOrWhiteSpace($sbHost)) {
        $sbHost = 'sb-us-non-prod-dev-esb-scus.servicebus.windows.net'
    }

    # DNS lookup
    $dnsResult = @{
        host      = $sbHost
        addresses = @()
        error     = $null
    }

    try {
        $addresses = [System.Net.Dns]::GetHostAddresses($sbHost) |
                     ForEach-Object { $_.ToString() }
        $dnsResult.addresses = $addresses
        Write-Log -Message "DNS lookup for '$sbHost' succeeded. IP(s): $($addresses -join ', ')"
    }
    catch {
        $dnsResult.error = $_.Exception.Message
        Write-Log -Level 'ERROR' -Message "DNS lookup for '$sbHost' failed: $($dnsResult.error)"
    }

    # Outbound HTTP (public IP)
    $ipResult = @{
        url   = 'https://api.ipify.org?format=json'
        ip    = $null
        error = $null
    }

    try {
        Write-Log -Message "Calling outbound test endpoint: $($ipResult.url)"
        $ipResponse = Invoke-RestMethod -Uri $ipResult.url -Method Get -TimeoutSec 10
        if ($ipResponse -and $ipResponse.ip) {
            $ipResult.ip = $ipResponse.ip
            Write-Log -Message "Outbound HTTP test succeeded. Public IP: $($ipResult.ip)"
        }
        else {
            $ipResult.error = "No 'ip' field in response."
            Write-Log -Level 'WARN' -Message "Outbound HTTP test returned no 'ip' field."
        }
    }
    catch {
        $ipResult.error = $_.Exception.Message
        Write-Log -Level 'ERROR' -Message "Outbound HTTP test to api.ipify.org failed: $($ipResult.error)"
    }

    $body = @{
        dns = $dnsResult
        outboundHttp = $ipResult
    } | ConvertTo-Json -Depth 5

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = 200
        Body       = $body
        Headers    = @{ "Content-Type" = "application/json" }
    })
}
catch {
    Write-Log -Level 'ERROR' -Message "Unhandled error: $($_.Exception.Message)"
    Send-ErrorEmail `
        -Subject "Azure Function net-test error" `
        -Body "Unhandled net-test error:`n`n$($_ | Out-String)" `
        -Context @{ Function = 'net-test-us' }
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = 500
        Body       = "Error: $($_.Exception.Message)"
    })
}


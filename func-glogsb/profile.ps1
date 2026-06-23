# /home/site/wwwroot/profile.ps1  (in repo: func-gpmsgsb/profile.ps1)
Write-Host "Function startup profile loaded. No Az modules required."

function Invoke-IbThrottleDelay {
    param(
        [string]$SettingName = 'intapp__ibThrottleSeconds',
        [int]$DefaultSeconds = 1
    )

    $delaySeconds = $DefaultSeconds
    $rawDelay = [Environment]::GetEnvironmentVariable($SettingName)

    if (-not [string]::IsNullOrWhiteSpace($rawDelay)) {
        $parsedDelay = 0
        if ([int]::TryParse($rawDelay, [ref]$parsedDelay)) {
            $delaySeconds = $parsedDelay
        }
        else {
            Write-Host "WARN: Invalid $SettingName value '$rawDelay'. Using default delay of $DefaultSeconds second(s)."
        }
    }

    if ($delaySeconds -lt 0) {
        Write-Host "WARN: Negative $SettingName value '$delaySeconds'. Using 0 seconds."
        $delaySeconds = 0
    }

    if ($delaySeconds -gt 0) {
        Start-Sleep -Seconds $delaySeconds
    }
}

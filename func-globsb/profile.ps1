# /home/site/wwwroot/profile.ps1  (in repo: func-globsb/profile.ps1)
Write-Host "Function startup profile loaded. No Az modules required."
function Send-ErrorEmail {
    param(
        [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][string]$Body,
        [hashtable]$Context
    )

    $smtpServer = $env:errorEmail__smtpServer
    $smtpUserName = $env:errorEmail__smtpUserName
    $smtpTo = $env:errorEmail__to
    $smtpFrom = $env:errorEmail__from
    $smtpPort = if ([string]::IsNullOrWhiteSpace($env:errorEmail__smtpPort)) { 587 } else { [int]$env:errorEmail__smtpPort }

    if ([string]::IsNullOrWhiteSpace($smtpServer) -or
        [string]::IsNullOrWhiteSpace($smtpUserName) -or
        [string]::IsNullOrWhiteSpace($smtpTo) -or
        [string]::IsNullOrWhiteSpace($smtpFrom)) {
        Write-Host "WARN: Error email not sent; missing one or more errorEmail__ SMTP settings."
        return
    }

    $mail = [System.Net.Mail.MailMessage]::new()
    $client = $null

    try {
        $mail.From = [System.Net.Mail.MailAddress]::new($smtpFrom)

        foreach ($address in ($smtpTo -split '[;,]')) {
            if (-not [string]::IsNullOrWhiteSpace($address)) {
                $mail.To.Add($address.Trim())
            }
        }

        if ($mail.To.Count -eq 0) {
            Write-Host "WARN: Error email not sent; errorEmail__to did not contain any valid recipients."
            return
        }

        $siteName = if ([string]::IsNullOrWhiteSpace($env:WEBSITE_SITE_NAME)) { 'Azure Function App' } else { $env:WEBSITE_SITE_NAME }
        $mail.Subject = "[$siteName] $Subject"
        $mail.Body = @"
$Body

---
Function App: $siteName
UTC: $((Get-Date).ToUniversalTime().ToString('o'))
"@
        $mail.IsBodyHtml = $false

        if ($Context) {
            foreach ($key in $Context.Keys) {
                $value = [string]$Context[$key]
                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    $mail.Headers.Add("X-Azure-Function-$key", $value)
                }
            }
        }

        $client = [System.Net.Mail.SmtpClient]::new($smtpServer, $smtpPort)
        $client.EnableSsl = $true
        $client.UseDefaultCredentials = $false
        $client.Credentials = [System.Net.NetworkCredential]::new($smtpUserName, [string]::Empty)
        $client.Send($mail)

        Write-Host "Error email sent to $smtpTo via $smtpServer`:$smtpPort with TLS enabled."
    }
    catch {
        Write-Host "WARN: Error email send failed: $($_.Exception.Message)"
    }
    finally {
        if ($client) { $client.Dispose() }
        if ($mail) { $mail.Dispose() }
    }
}


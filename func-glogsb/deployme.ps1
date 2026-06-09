<#
.SYNOPSIS
  Syncs required app settings and ZIP-deploys a PowerShell Azure Function App.

.DESCRIPTION
  Scans this Function App project for app setting references, creates any
  missing Azure Function App settings with a placeholder value, then deploys
  the local function app files by ZIP deploy.

  Pass the target Function App and resource group when running.

.PARAMETER ResourceGroup
  Resource group containing the Function App.

.PARAMETER FunctionApp
  Name of the target Function App.

.PARAMETER ProjectPath
  Local path to the Function App project folder.

.PARAMETER SkipAppSettingsSync
  Skips the pre-deploy missing-app-settings check/create step.

.PARAMETER PlaceholderValue
  Placeholder value used when creating missing app settings.

.PARAMETER ServiceBusConnectionMode
  How to interpret Service Bus binding connection names found in function.json.
  Identity creates <connection>__fullyQualifiedNamespace.
  ConnectionString creates <connection>.
  None ignores binding connection names.
#>

param(
  [string]$ResourceGroup,
  [string]$FunctionApp,
  [string]$ProjectPath   = $PSScriptRoot,
  [switch]$SkipAppSettingsSync,
  [string]$PlaceholderValue = 'TODO_SET_ME',
  [ValidateSet('Identity','ConnectionString','None')]
  [string]$ServiceBusConnectionMode = 'Identity'
)

$ErrorActionPreference = "Stop"

function Assert-RequiredValue {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "Please provide the ResourceGroup and FunctionApp command line options. Example: .\deployme.ps1 -ResourceGroup ""rg-name"" -FunctionApp ""func-name"""
    }
}

function Ensure-AzureCliLogin {
    Write-Host "Checking Azure CLI login status..." -ForegroundColor Cyan
    try {
        $accountInfo = az account show --output json | ConvertFrom-Json
        if ($null -eq $accountInfo -or -not $accountInfo.id) {
            throw "No active Azure session found."
        }
        Write-Host "Logged in as $($accountInfo.user.name)" -ForegroundColor Green
    }
    catch {
        Write-Host "No active Azure session found. Launching az login..." -ForegroundColor Yellow
        az login | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Azure login failed."
        }
    }
}

function Add-SettingName {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.SortedSet[string]]$Set,
        [Parameter(Mandatory)][string]$Name
    )

    if (-not [string]::IsNullOrWhiteSpace($Name)) {
        [void]$Set.Add($Name.Trim())
    }
}

function Get-DesiredFunctionAppSettings {
    param(
        [Parameter(Mandatory)][string]$ResolvedProjectPath,
        [Parameter(Mandatory)][ValidateSet('Identity','ConnectionString','None')]
        [string]$ServiceBusConnectionMode
    )

    $desired = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $builtInExcludes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    @(
        'AzureWebJobsFunctionName',
        'AZURE_FUNCTIONAPP_NAME',
        'AZURE_FUNCTIONAPP_RESOURCE_GROUP',
        'azure_fa_func_glogsb',
        'azure_fa_func_glogsb_net',
        'azure_fa_rg',
        'FUNCTION_NAME',
        'FUNCTIONS_FUNCTION_NAME',
        'TEMP',
        'TMP',
        'WEBSITE_SITE_NAME'
    ) | ForEach-Object { [void]$builtInExcludes.Add($_) }

    $psFiles = Get-ChildItem -Path $ResolvedProjectPath -Recurse -File -Include '*.ps1','*.psm1' |
        Where-Object { $_.FullName -notmatch '\\(bin|obj|publish|release)\\' }

    foreach ($file in $psFiles) {
        $content = Get-Content -Raw -Path $file.FullName
        foreach ($match in [regex]::Matches($content, '\$env:([A-Za-z_][A-Za-z0-9_]*(?:__[A-Za-z0-9_]+)*)')) {
            $name = $match.Groups[1].Value
            if (-not $builtInExcludes.Contains($name)) {
                Add-SettingName -Set $desired -Name $name
            }
        }
    }

    $jsonFiles = Get-ChildItem -Path $ResolvedProjectPath -Recurse -File -Filter 'function.json'
    foreach ($file in $jsonFiles) {
        $content = Get-Content -Raw -Path $file.FullName

        foreach ($match in [regex]::Matches($content, '%([A-Za-z_][A-Za-z0-9_]*)%')) {
            $name = $match.Groups[1].Value
            if (-not $builtInExcludes.Contains($name)) {
                Add-SettingName -Set $desired -Name $name
            }
        }

        if ($ServiceBusConnectionMode -ne 'None') {
            try {
                $json = $content | ConvertFrom-Json -ErrorAction Stop
                foreach ($binding in @($json.bindings)) {
                    if ($binding.type -like 'serviceBus*' -and -not [string]::IsNullOrWhiteSpace($binding.connection)) {
                        $connectionName = [string]$binding.connection
                        if ($ServiceBusConnectionMode -eq 'Identity') {
                            Add-SettingName -Set $desired -Name "$connectionName`__fullyQualifiedNamespace"
                        }
                        else {
                            Add-SettingName -Set $desired -Name $connectionName
                        }
                    }
                }
            }
            catch {
                Write-Warning "Could not parse $($file.FullName): $($_.Exception.Message)"
            }
        }
    }

    return $desired
}

function Sync-FunctionAppSettings {
    param(
        [Parameter(Mandatory)][string]$ResolvedProjectPath,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$FunctionApp,
        [Parameter(Mandatory)][string]$PlaceholderValue,
        [Parameter(Mandatory)][ValidateSet('Identity','ConnectionString','None')]
        [string]$ServiceBusConnectionMode
    )

    $desired = Get-DesiredFunctionAppSettings `
        -ResolvedProjectPath $ResolvedProjectPath `
        -ServiceBusConnectionMode $ServiceBusConnectionMode

    Write-Host "Discovered $($desired.Count) desired app settings under $ResolvedProjectPath." -ForegroundColor Cyan
    $desired | ForEach-Object { Write-Host "  $_" }

    $currentSettings = az functionapp config appsettings list `
        --resource-group $ResourceGroup `
        --name $FunctionApp `
        --output json | ConvertFrom-Json

    if ($LASTEXITCODE -ne 0) {
        throw "Could not read app settings for $FunctionApp."
    }

    $existing = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($setting in @($currentSettings)) {
        [void]$existing.Add([string]$setting.name)
    }

    $missing = @($desired | Where-Object { -not $existing.Contains($_) })

    if ($missing.Count -eq 0) {
        Write-Host "All discovered app settings already exist on $FunctionApp." -ForegroundColor Green
        return
    }

    Write-Host "Missing $($missing.Count) app setting(s) on ${FunctionApp}:" -ForegroundColor Yellow
    $missing | ForEach-Object { Write-Host "  $_" }

    $settingsToCreate = $missing | ForEach-Object { "$_=$PlaceholderValue" }
    Write-Host "Creating missing app settings with placeholder value '$PlaceholderValue'..." -ForegroundColor Cyan
    az functionapp config appsettings set `
        --resource-group $ResourceGroup `
        --name $FunctionApp `
        --settings $settingsToCreate | Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create one or more app settings."
    }

    Write-Host "Created $($missing.Count) missing app setting(s). Replace placeholder values before relying on the app." -ForegroundColor Green
}

Assert-RequiredValue -Name 'ResourceGroup' -Value $ResourceGroup
Assert-RequiredValue -Name 'FunctionApp' -Value $FunctionApp

$resolvedProjectPath = (Resolve-Path -Path $ProjectPath).Path

Ensure-AzureCliLogin

if (-not $SkipAppSettingsSync) {
    Sync-FunctionAppSettings `
        -ResolvedProjectPath $resolvedProjectPath `
        -ResourceGroup $ResourceGroup `
        -FunctionApp $FunctionApp `
        -PlaceholderValue $PlaceholderValue `
        -ServiceBusConnectionMode $ServiceBusConnectionMode
}
else {
    Write-Host "Skipping Function App settings sync." -ForegroundColor Yellow
}

# Resolve paths
$publishDir = Join-Path $env:TEMP "func-publish-$FunctionApp"
$zipPath    = Join-Path $env:TEMP "$FunctionApp.zip"

if (Test-Path $publishDir) { Remove-Item $publishDir -Recurse -Force }
if (Test-Path $zipPath)    { Remove-Item $zipPath -Force }

New-Item -ItemType Directory -Path $publishDir | Out-Null

# Copy function app files
Write-Host "Preparing PowerShell Function App package..." -ForegroundColor Cyan
Copy-Item -Path (Join-Path $resolvedProjectPath "*") -Destination $publishDir -Recurse -Force

# Sanity check
$hostJson = Join-Path $publishDir "host.json"
if (-not (Test-Path $hostJson)) {
    throw "host.json was not found in publish output. Refusing to deploy."
}

# Zip the CONTENTS of publish folder, not the folder itself
Write-Host "Creating ZIP package..." -ForegroundColor Cyan
Push-Location $publishDir
try {
    Compress-Archive -Path * -DestinationPath $zipPath -Force
}
finally {
    Pop-Location
}

# Deploy
Write-Host "Deploying ZIP package to $FunctionApp in $ResourceGroup..." -ForegroundColor Cyan
az functionapp deployment source config-zip `
  --resource-group $ResourceGroup `
  --name $FunctionApp `
  --src $zipPath

if ($LASTEXITCODE -ne 0) {
    throw "ZIP deployment failed."
}

Write-Host "Deployment complete." -ForegroundColor Green

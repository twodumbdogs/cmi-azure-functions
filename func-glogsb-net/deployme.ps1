<#
.SYNOPSIS
  Builds and ZIP-deploys a .NET isolated Azure Function App.

.DESCRIPTION
  Publishes the project to a local output folder, zips the published files,
  and deploys them to the target Function App using Azure CLI ZIP deploy.

  Pass the target Function App and resource group when running.

.PARAMETER ResourceGroup
  Resource group containing the Function App.

.PARAMETER FunctionApp
  Name of the target Function App.

.PARAMETER ProjectPath
  Local path to the Function App project folder.

.PARAMETER Configuration
  Build configuration. Default is Release.
#>

param(
  [string]$ResourceGroup,
  [string]$FunctionApp,
  [string]$ProjectPath   = $PSScriptRoot,
  [ValidateSet("Debug","Release")]
  [string]$Configuration = "Release"
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

Assert-RequiredValue -Name 'ResourceGroup' -Value $ResourceGroup
Assert-RequiredValue -Name 'FunctionApp' -Value $FunctionApp

# Check Azure CLI login
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

# Resolve paths
$publishDir = Join-Path $env:TEMP "func-publish-$FunctionApp"
$zipPath    = Join-Path $env:TEMP "$FunctionApp.zip"

if (Test-Path $publishDir) { Remove-Item $publishDir -Recurse -Force }
if (Test-Path $zipPath)    { Remove-Item $zipPath -Force }

# Build/publish
Write-Host "Publishing .NET Function App..." -ForegroundColor Cyan
dotnet publish $ProjectPath -c $Configuration -o $publishDir
if ($LASTEXITCODE -ne 0) {
    throw "dotnet publish failed."
}

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

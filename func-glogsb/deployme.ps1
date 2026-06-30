<#
.SYNOPSIS
  ZIP-deploys this PowerShell Azure Function App.

.DESCRIPTION
  Copies the function app files to a temporary publish folder, zips the
  contents, and deploys them to the target Function App using Azure CLI.
  App settings and networking are left untouched.

  For known environments, the first argument can be an environment name
  instead of explicit -ResourceGroup and -FunctionApp values.

.PARAMETER ResourceGroup
  Resource group containing the target Function App, or a known environment
  name when FunctionApp is omitted: dev, pre-prod, preprod, qa, or prod.

.PARAMETER FunctionApp
  Name of the target Function App.

.PARAMETER ProjectPath
  Local path containing host.json. Defaults to this script's folder.
#>

param(
  [string]$ResourceGroup,
  [string]$FunctionApp,
  [string]$ProjectPath = $PSScriptRoot
)

$ErrorActionPreference = "Stop"

function Show-Usage {
    $scriptName = Split-Path -Leaf $PSCommandPath
    Write-Host ""
    Write-Host "Usage:" -ForegroundColor Cyan
    Write-Host "  .\$scriptName <environment>"
    Write-Host "  .\$scriptName -ResourceGroup <resource-group> -FunctionApp <function-app> [-ProjectPath <path>]"
    Write-Host ""
    Write-Host "Known environments:" -ForegroundColor Cyan
    Write-Host "  dev      -> rg-glogsb-dev-uksouth-001 / func-glogsb-dev-uksouth-001"
    Write-Host "  pre-prod -> rg-glogsb-qa-ukwest-001 / func-glogsb-qa-ukwest-001"
    Write-Host "  prod     -> not configured yet"
    Write-Host ""
    Write-Host "Examples:" -ForegroundColor Cyan
    Write-Host "  .\$scriptName dev"
    Write-Host "  .\$scriptName pre-prod"
    Write-Host "  .\$scriptName -ResourceGroup ""rg-glogsb-dev-uksouth-001"" -FunctionApp ""func-glogsb-dev-uksouth-001"""
    Write-Host "  .\$scriptName -ResourceGroup ""rg-glogsb-qa-ukwest-001"" -FunctionApp ""func-glogsb-qa-ukwest-001"""
    Write-Host ""
}

function Resolve-DeploymentTarget {
    param(
        [string]$RequestedResourceGroup,
        [string]$RequestedFunctionApp
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedFunctionApp)) {
        return [pscustomobject]@{
            ResourceGroup    = $RequestedResourceGroup
            FunctionApp      = $RequestedFunctionApp
            EnvironmentName  = $null
        }
    }

    $environmentName = $RequestedResourceGroup
    if ([string]::IsNullOrWhiteSpace($environmentName)) {
        return [pscustomobject]@{
            ResourceGroup    = $RequestedResourceGroup
            FunctionApp      = $RequestedFunctionApp
            EnvironmentName  = $null
        }
    }

    switch -Regex ($environmentName.Trim()) {
        '^(?i:dev)$' {
            return [pscustomobject]@{
                ResourceGroup    = "rg-glogsb-dev-uksouth-001"
                FunctionApp      = "func-glogsb-dev-uksouth-001"
                EnvironmentName  = "dev"
            }
        }
        '^(?i:pre-?prod|qa)$' {
            return [pscustomobject]@{
                ResourceGroup    = "rg-glogsb-qa-ukwest-001"
                FunctionApp      = "func-glogsb-qa-ukwest-001"
                EnvironmentName  = "pre-prod"
            }
        }
        '^(?i:prod|production)$' {
            throw "Prod target is not configured yet. Use dev/pre-prod, or pass -ResourceGroup and -FunctionApp explicitly when prod exists."
        }
        default {
            return [pscustomobject]@{
                ResourceGroup    = $RequestedResourceGroup
                FunctionApp      = $RequestedFunctionApp
                EnvironmentName  = $null
            }
        }
    }
}

$deploymentTarget = Resolve-DeploymentTarget `
    -RequestedResourceGroup $ResourceGroup `
    -RequestedFunctionApp $FunctionApp

$ResourceGroup = $deploymentTarget.ResourceGroup
$FunctionApp = $deploymentTarget.FunctionApp

if (-not [string]::IsNullOrWhiteSpace($deploymentTarget.EnvironmentName)) {
    Write-Host "Using $($deploymentTarget.EnvironmentName) deployment target:" -ForegroundColor Cyan
    Write-Host "  Resource group: $ResourceGroup" -ForegroundColor Cyan
    Write-Host "  Function app:   $FunctionApp" -ForegroundColor Cyan
}

if ([string]::IsNullOrWhiteSpace($ResourceGroup) -or [string]::IsNullOrWhiteSpace($FunctionApp)) {
    Show-Usage
    throw "Please provide an environment name, or both -ResourceGroup and -FunctionApp."
}

$resolvedProjectPath = (Resolve-Path -LiteralPath $ProjectPath).Path
$hostJson = Join-Path $resolvedProjectPath "host.json"
if (-not (Test-Path -LiteralPath $hostJson)) {
    throw "host.json was not found at '$resolvedProjectPath'. Pass -ProjectPath with the function app folder."
}

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

$publishDir = Join-Path $env:TEMP "func-publish-$FunctionApp"
$zipPath = Join-Path $env:TEMP "$FunctionApp.zip"

if (Test-Path -LiteralPath $publishDir) { Remove-Item -LiteralPath $publishDir -Recurse -Force }
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

New-Item -ItemType Directory -Path $publishDir | Out-Null

Write-Host "Preparing PowerShell Function App package from $resolvedProjectPath..." -ForegroundColor Cyan
Copy-Item -Path (Join-Path $resolvedProjectPath "*") -Destination $publishDir -Recurse -Force

$publishedHostJson = Join-Path $publishDir "host.json"
if (-not (Test-Path -LiteralPath $publishedHostJson)) {
    throw "host.json was not found in publish output. Refusing to deploy."
}

Write-Host "Creating ZIP package..." -ForegroundColor Cyan
Push-Location $publishDir
try {
    Compress-Archive -Path * -DestinationPath $zipPath -Force
}
finally {
    Pop-Location
}

Write-Host "Deploying ZIP package to $FunctionApp in $ResourceGroup..." -ForegroundColor Cyan
az functionapp deployment source config-zip `
  --resource-group $ResourceGroup `
  --name $FunctionApp `
  --src $zipPath

if ($LASTEXITCODE -ne 0) {
    throw "ZIP deployment failed."
}

Write-Host "Deployment complete." -ForegroundColor Green

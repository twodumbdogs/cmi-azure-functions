<#
.SYNOPSIS
  Deploys the current Azure Function App code to Azure via ZIP deploy.

.DESCRIPTION
  Compresses your local function project and publishes it to the target
  Function App using the Azure CLI.  Only code is replaced — app settings
  and networking are left untouched.

.PARAMETER ResourceGroup
  The name of the resource group containing the Function App.

.PARAMETER FunctionApp
  The name of the Function App to deploy to.

.PARAMETER ProjectPath
  The local path containing host.json (default: current directory).
#>

param(
  [string]$ResourceGroup = "rg-gpmsgsb-dev-uksouth-001",
  [string]$FunctionApp   = "func-gpmsgsb-dev-uksouth-001",
  [string]$ProjectPath   = (Get-Location).Path
)

# =========================================
#  Ensure Azure CLI session is active
# =========================================
Write-Host "🔍 Checking Azure CLI login status..." -ForegroundColor Cyan

try {
    $accountInfo = az account show --output json | ConvertFrom-Json
    if ($null -eq $accountInfo -or -not $accountInfo.id) {
        throw "No active Azure session found"
    }

    Write-Host "✅ Already logged in as $($accountInfo.user.name)" -ForegroundColor Green
}
catch {
    Write-Host "🧠 Not logged in — launching az login..." -ForegroundColor Yellow
    az login | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $accountInfo = az account show --output json | ConvertFrom-Json
        Write-Host "✅ Logged in successfully as $($accountInfo.user.name)" -ForegroundColor Green
    }
    else {
        Write-Host "❌ Login failed. Please authenticate manually and rerun." -ForegroundColor Red
        exit 1
    }
}

$zip = Join-Path $env:TEMP "function-deploy.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }

Write-Host "📦 Creating deployment package..." -ForegroundColor Cyan
Compress-Archive -Path (Join-Path $ProjectPath '*') -DestinationPath $zip -Force

Write-Host "🚀 Deploying to $FunctionApp in $ResourceGroup ..." -ForegroundColor Cyan
az functionapp deployment source config-zip `
  --resource-group $ResourceGroup `
  --name $FunctionApp `
  --src $zip

if ($LASTEXITCODE -eq 0) {
  Write-Host "✅ Deployment complete!" -ForegroundColor Green
} else {
  Write-Host "❌ Deployment failed." -ForegroundColor Red
}
$mk = az functionapp keys list `
   --name func-gpmsgsb-dev-uksouth-001 `
   --resource-group rg-gpmsgsb-dev-uksouth-001 `
   --query masterKey -o tsv

irm -Method POST "https://func-gpmsgsb-dev-uksouth-001.azurewebsites.net/admin/host/synctriggers?code=$mk"

Write-Host "✅ Triggers synchronized!" -ForegroundColor Green

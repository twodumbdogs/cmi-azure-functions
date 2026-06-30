<#
.SYNOPSIS
  Applies the optional SchemaRejects app settings for the CMI outbound Function App.

.DESCRIPTION
  These settings control schema reject logging without redeploying the code.

  This script intentionally does not set SQL connection strings or secrets.
  Each environment should already have its SQL connection settings configured
  as Function App settings.

  For known environments, the first argument can be an environment name
  instead of explicit -ResourceGroupName and -FunctionAppName values.

  Required SQL connection settings are still either:

    Sql__ConnectionString

  Or both:

    Sql__Server
    Sql__Database

  Recommended default values:

    SchemaRejects__Enabled=true
    SchemaRejects__TableName=dbo._NRF_sbSchemaRejects
    SchemaRejects__CommandTimeoutSeconds=30
    SchemaRejects__WriteMergedPayload=true
    SchemaRejects__FailOpen=true
#>

param(
    [Alias("ResourceGroup", "rg")]
    [string]$ResourceGroupName,

    [Alias("FunctionApp", "fa")]
    [string]$FunctionAppName,

    [ValidateSet("true", "false")]
    [string]$Enabled = "true",

    [string]$TableName = "dbo._NRF_sbSchemaRejects",

    [int]$CommandTimeoutSeconds = 30,

    [ValidateSet("true", "false")]
    [string]$WriteMergedPayload = "true",

    [ValidateSet("true", "false")]
    [string]$FailOpen = "true"
)

$ErrorActionPreference = "Stop"

function Show-Usage {
    $scriptName = Split-Path -Leaf $PSCommandPath

    Write-Host ""
    Write-Host "Usage:" -ForegroundColor Cyan
    Write-Host "  .\$scriptName <environment>"
    Write-Host "  .\$scriptName -ResourceGroupName <resource-group> -FunctionAppName <function-app>"
    Write-Host ""
    Write-Host "Known environments:" -ForegroundColor Cyan
    Write-Host "  dev      -> rg-glogsb-dev-uksouth-001 / func-glogsb-net-dev-uksouth-001"
    Write-Host "  pre-prod -> rg-glogsb-qa-ukwest-001 / func-glogsb-net-qa-ukwest-001"
    Write-Host "  prod     -> not configured yet"
    Write-Host ""
    Write-Host "Examples:" -ForegroundColor Cyan
    Write-Host "  .\$scriptName dev"
    Write-Host "  .\$scriptName pre-prod"
    Write-Host "  .\$scriptName -rg ""rg-glogsb-dev-uksouth-001"" -fa ""func-glogsb-net-dev-uksouth-001"""
    Write-Host "  .\$scriptName -rg ""rg-glogsb-qa-ukwest-001"" -fa ""func-glogsb-net-qa-ukwest-001"""
    Write-Host ""
}

function Resolve-DeploymentTarget {
    param(
        [string]$RequestedResourceGroupName,
        [string]$RequestedFunctionAppName
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedFunctionAppName)) {
        return [pscustomobject]@{
            ResourceGroupName = $RequestedResourceGroupName
            FunctionAppName   = $RequestedFunctionAppName
            EnvironmentName   = $null
        }
    }

    $environmentName = $RequestedResourceGroupName
    if ([string]::IsNullOrWhiteSpace($environmentName)) {
        return [pscustomobject]@{
            ResourceGroupName = $RequestedResourceGroupName
            FunctionAppName   = $RequestedFunctionAppName
            EnvironmentName   = $null
        }
    }

    switch -Regex ($environmentName.Trim()) {
        '^(?i:dev)$' {
            return [pscustomobject]@{
                ResourceGroupName = "rg-glogsb-dev-uksouth-001"
                FunctionAppName   = "func-glogsb-net-dev-uksouth-001"
                EnvironmentName   = "dev"
            }
        }
        '^(?i:pre-?prod|qa)$' {
            return [pscustomobject]@{
                ResourceGroupName = "rg-glogsb-qa-ukwest-001"
                FunctionAppName   = "func-glogsb-net-qa-ukwest-001"
                EnvironmentName   = "pre-prod"
            }
        }
        '^(?i:prod|production)$' {
            throw "Prod target is not configured yet. Use dev/pre-prod, or pass -ResourceGroupName and -FunctionAppName explicitly when prod exists."
        }
        default {
            return [pscustomobject]@{
                ResourceGroupName = $RequestedResourceGroupName
                FunctionAppName   = $RequestedFunctionAppName
                EnvironmentName   = $null
            }
        }
    }
}

$deploymentTarget = Resolve-DeploymentTarget `
    -RequestedResourceGroupName $ResourceGroupName `
    -RequestedFunctionAppName $FunctionAppName

$ResourceGroupName = $deploymentTarget.ResourceGroupName
$FunctionAppName = $deploymentTarget.FunctionAppName

if (-not [string]::IsNullOrWhiteSpace($deploymentTarget.EnvironmentName)) {
    Write-Host "Using $($deploymentTarget.EnvironmentName) deployment target:" -ForegroundColor Cyan
    Write-Host "  Resource group: $ResourceGroupName" -ForegroundColor Cyan
    Write-Host "  Function app:   $FunctionAppName" -ForegroundColor Cyan
}

if ([string]::IsNullOrWhiteSpace($ResourceGroupName) -or [string]::IsNullOrWhiteSpace($FunctionAppName)) {
    Show-Usage
    throw "Please provide an environment name, or both -ResourceGroupName and -FunctionAppName."
}

Write-Host "Applying SchemaRejects app settings..." -ForegroundColor Cyan
Write-Host "Resource Group: $ResourceGroupName"
Write-Host "Function App:   $FunctionAppName"
Write-Host "Enabled:        $Enabled"
Write-Host "Table Name:     $TableName"
Write-Host "Timeout:        $CommandTimeoutSeconds"
Write-Host "Write Payload:  $WriteMergedPayload"
Write-Host "Fail Open:      $FailOpen"
Write-Host ""

az functionapp config appsettings set `
    --resource-group $ResourceGroupName `
    --name $FunctionAppName `
    --settings `
        SchemaRejects__Enabled="$Enabled" `
        SchemaRejects__TableName="$TableName" `
        SchemaRejects__CommandTimeoutSeconds="$CommandTimeoutSeconds" `
        SchemaRejects__WriteMergedPayload="$WriteMergedPayload" `
        SchemaRejects__FailOpen="$FailOpen"

if ($LASTEXITCODE -ne 0) {
    throw "Failed to apply SchemaRejects app settings."
}

Write-Host ""
Write-Host "SchemaRejects app settings applied." -ForegroundColor Green

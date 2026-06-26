<#
.SYNOPSIS
  Applies the optional SchemaRejects app settings for the CMI outbound Function App.

.DESCRIPTION
  These settings control schema reject logging without redeploying the code.

  This script intentionally does not set SQL connection strings or secrets.

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
    [string]$ResourceGroupName = "rg-glogsb-dev-uksouth-001",

    [Alias("FunctionApp", "fa")]
    [string]$FunctionAppName = "func-glogsb-net-dev-uksouth-001",

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
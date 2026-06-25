<#
.SYNOPSIS
  Applies the optional SchemaRejects app settings for the CMI outbound Function App.

.DESCRIPTION
  These settings control schema reject logging without redeploying the code.
  This script intentionally does not set SQL connection strings or secrets.

  Required SQL connection settings are still:
    Sql__ConnectionString

  Or:
    Sql__Server
    Sql__Database
#>

param(
    [string]$ResourceGroup = "rg-glogsb-dev-uksouth-001",
    [string]$FunctionApp   = "func-glogsb-net-dev-uksouth-001"
)

$ErrorActionPreference = "Stop"

az functionapp config appsettings set `
    --resource-group $ResourceGroup `
    --name $FunctionApp `
    --settings `
        SchemaRejects__Enabled="true" `
        SchemaRejects__TableName="dbo._NRF_sbSchemaRejects" `
        SchemaRejects__CommandTimeoutSeconds="30" `
        SchemaRejects__WriteMergedPayload="true" `
        SchemaRejects__FailOpen="true"

if ($LASTEXITCODE -ne 0) {
    throw "Failed to apply SchemaRejects app settings."
}

Write-Host "SchemaRejects app settings applied." -ForegroundColor Green

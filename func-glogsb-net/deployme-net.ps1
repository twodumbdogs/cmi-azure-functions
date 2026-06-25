<#
.SYNOPSIS
  Builds and ZIP-deploys a .NET isolated Azure Function App.

.DESCRIPTION
  Publishes the Function App project to a temporary output folder, zips the
  published files, and deploys the ZIP to Azure Functions using Azure CLI.

  This script is resilient to being launched from the "wrong" folder:
  - If -ProjectPath is provided, that path is used.
  - Otherwise, the script starts at its own folder and walks upward until it
    finds a folder containing host.json and exactly one .csproj file.
  - dotnet publish is run against the resolved .csproj file, not the current
    working directory.

  The script can also validate Function App settings before deployment:
  - Confirms the Function App has SQL settings configured.
  - Ensures SchemaRejects settings exist by adding defaults only when missing.
  - Existing app setting values are never overwritten by the default check.

.PARAMETER ResourceGroupName
  Resource group containing the target Function App.
  Aliases: ResourceGroup, rg

.PARAMETER FunctionAppName
  Name of the target Function App.
  Aliases: FunctionApp, fa

.PARAMETER ProjectPath
  Local path to the Function App project folder. If omitted, the script auto-detects
  the project folder by walking upward from this script's folder.

.PARAMETER Configuration
  Build configuration. Default is Release.

.PARAMETER OutputRoot
  Folder where temporary publish output and ZIP package are written. Default is $env:TEMP.

.PARAMETER SkipAzureLoginCheck
  Skip the Azure CLI account check/login prompt.

.PARAMETER SkipAppSettingsCheck
  Skip all Azure Function app setting checks.

.PARAMETER SkipSchemaRejectSettingsEnsure
  Check required SQL settings, but do not add missing SchemaRejects default settings.

.PARAMETER KeepPublishFolder
  Keep the temporary dotnet publish output folder after deployment.
#>

[CmdletBinding()]
param(
    [Alias("ResourceGroup", "rg")]
    [string]$ResourceGroupName,

    [Alias("FunctionApp", "fa")]
    [string]$FunctionAppName,

    [string]$ProjectPath,

    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",

    [string]$OutputRoot = $env:TEMP,

    [switch]$SkipAzureLoginCheck,
    [switch]$SkipAppSettingsCheck,
    [switch]$SkipSchemaRejectSettingsEnsure,
    [switch]$KeepPublishFolder
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Show-Usage {
    $scriptName = Split-Path -Leaf $PSCommandPath

    Write-Host ""
    Write-Host "Usage:" -ForegroundColor Cyan
    Write-Host "  .\$scriptName -ResourceGroupName <resource-group> -FunctionAppName <function-app> [-ProjectPath <path>] [-Configuration Debug|Release]"
    Write-Host ""
    Write-Host "Aliases:" -ForegroundColor Cyan
    Write-Host "  -ResourceGroupName can also be passed as -ResourceGroup or -rg"
    Write-Host "  -FunctionAppName can also be passed as -FunctionApp or -fa"
    Write-Host ""
    Write-Host "Examples:" -ForegroundColor Cyan
    Write-Host "  .\$scriptName -ResourceGroupName ""rg-glogsb-dev-uksouth-001"" -FunctionAppName ""func-glogsb-net-dev-uksouth-001"""
    Write-Host "  .\$scriptName -rg ""rg-glogsb-qa1-uksouth-001"" -fa ""func-glogsb-net-qa1-uksouth-001"""
    Write-Host "  .\$scriptName -rg ""rg-glogsb-prod-uksouth-001"" -fa ""func-glogsb-net-prod-uksouth-001"" -SkipSchemaRejectSettingsEnsure"
    Write-Host ""
}

function Assert-CommandAvailable {
    param(
        [Parameter(Mandatory)]
        [string]$CommandName
    )

    if (-not (Get-Command $CommandName -ErrorAction SilentlyContinue)) {
        throw "Required command '$CommandName' was not found in PATH."
    }
}

function Get-FunctionProjectInfo {
    param(
        [Parameter(Mandatory)]
        [string]$CandidatePath
    )

    if (-not (Test-Path -LiteralPath $CandidatePath -PathType Container)) {
        return $null
    }

    $hostJsonPath = Join-Path $CandidatePath "host.json"
    if (-not (Test-Path -LiteralPath $hostJsonPath -PathType Leaf)) {
        return $null
    }

    $projectFiles = @(Get-ChildItem -LiteralPath $CandidatePath -Filter "*.csproj" -File)

    if ($projectFiles.Count -eq 0) {
        throw "Found host.json at '$CandidatePath', but no .csproj file was found there."
    }

    if ($projectFiles.Count -gt 1) {
        $projectList = ($projectFiles | Select-Object -ExpandProperty Name) -join ", "
        throw "Found host.json at '$CandidatePath', but multiple .csproj files were found: $projectList. Pass -ProjectPath explicitly."
    }

    [pscustomobject]@{
        ProjectPath = (Resolve-Path -LiteralPath $CandidatePath).Path
        ProjectFile = $projectFiles[0].FullName
        HostJson    = $hostJsonPath
    }
}

function Resolve-FunctionProject {
    param(
        [string]$RequestedProjectPath
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedProjectPath)) {
        $resolvedPath = (Resolve-Path -LiteralPath $RequestedProjectPath).Path
        $projectInfo = Get-FunctionProjectInfo -CandidatePath $resolvedPath

        if ($null -eq $projectInfo) {
            throw "ProjectPath '$resolvedPath' is not a Function App project folder. Expected host.json and exactly one .csproj file."
        }

        return $projectInfo
    }

    $startPath = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($startPath)) {
        $startPath = (Get-Location).Path
    }

    $current = (Resolve-Path -LiteralPath $startPath).Path

    while (-not [string]::IsNullOrWhiteSpace($current)) {
        $projectInfo = Get-FunctionProjectInfo -CandidatePath $current
        if ($null -ne $projectInfo) {
            return $projectInfo
        }

        $parent = Split-Path -Parent $current
        if ($parent -eq $current) {
            break
        }

        $current = $parent
    }

    throw "Could not auto-detect the Function App project folder from '$startPath'. Pass -ProjectPath with the folder containing host.json and the .csproj file."
}

function Test-AzureCliLogin {
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

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [Parameter(Mandatory)]
        [string]$ErrorMessage
    )

    & $ScriptBlock

    if ($LASTEXITCODE -ne 0) {
        throw $ErrorMessage
    }
}

function Get-FunctionAppSettingsMap {
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$FunctionAppName
    )

    Write-Host "Reading Function App settings for $FunctionAppName..." -ForegroundColor Cyan

    $settingsJson = az functionapp config appsettings list `
        --resource-group $ResourceGroupName `
        --name $FunctionAppName `
        --output json

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to read Function App settings for '$FunctionAppName'."
    }

    $settings = $settingsJson | ConvertFrom-Json
    $map = @{}

    foreach ($setting in @($settings)) {
        if ($null -ne $setting.name) {
            $map[$setting.name] = $setting.value
        }
    }

    return $map
}

function Test-AppSettingHasValue {
    param(
        [Parameter(Mandatory)]
        [hashtable]$SettingsMap,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if (-not $SettingsMap.ContainsKey($Name)) {
        return $false
    }

    $value = [string]$SettingsMap[$Name]
    return -not [string]::IsNullOrWhiteSpace($value)
}

function Assert-RequiredSqlSettingsExist {
    param(
        [Parameter(Mandatory)]
        [hashtable]$SettingsMap
    )

    $hasFullConnectionString = Test-AppSettingHasValue -SettingsMap $SettingsMap -Name "Sql__ConnectionString"
    $hasServer = Test-AppSettingHasValue -SettingsMap $SettingsMap -Name "Sql__Server"
    $hasDatabase = Test-AppSettingHasValue -SettingsMap $SettingsMap -Name "Sql__Database"

    if ($hasFullConnectionString) {
        Write-Host "SQL settings check passed: Sql__ConnectionString exists." -ForegroundColor Green
        return
    }

    if ($hasServer -and $hasDatabase) {
        Write-Host "SQL settings check passed: Sql__Server and Sql__Database exist." -ForegroundColor Green
        return
    }

    throw @"
Missing required SQL app settings.
Configure either:
  Sql__ConnectionString
or both:
  Sql__Server
  Sql__Database
"@
}

function Ensure-SchemaRejectAppSettings {
    param(
        [Parameter(Mandatory)]
        [hashtable]$SettingsMap,

        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$FunctionAppName
    )

    $defaults = [ordered]@{
        "SchemaRejects__Enabled"               = "true"
        "SchemaRejects__TableName"             = "dbo._NRF_sbSchemaRejects"
        "SchemaRejects__CommandTimeoutSeconds" = "30"
        "SchemaRejects__WriteMergedPayload"    = "true"
        "SchemaRejects__FailOpen"              = "true"
    }

    $missingSettings = [ordered]@{}

    foreach ($name in $defaults.Keys) {
        if (-not (Test-AppSettingHasValue -SettingsMap $SettingsMap -Name $name)) {
            $missingSettings[$name] = $defaults[$name]
        }
    }

    if ($missingSettings.Count -eq 0) {
        Write-Host "SchemaRejects app settings already exist. Existing values were left untouched." -ForegroundColor Green
        return
    }

    Write-Host "Adding missing SchemaRejects app settings. Existing values will not be overwritten:" -ForegroundColor Yellow
    foreach ($name in $missingSettings.Keys) {
        Write-Host "  $name=$($missingSettings[$name])" -ForegroundColor Yellow
    }

    $settingsArgs = @()
    foreach ($name in $missingSettings.Keys) {
        $settingsArgs += "$name=$($missingSettings[$name])"
    }

    az functionapp config appsettings set `
        --resource-group $ResourceGroupName `
        --name $FunctionAppName `
        --settings $settingsArgs `
        --output none

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to add missing SchemaRejects app settings."
    }

    Write-Host "Missing SchemaRejects app settings added." -ForegroundColor Green
}

if ([string]::IsNullOrWhiteSpace($ResourceGroupName) -or [string]::IsNullOrWhiteSpace($FunctionAppName)) {
    Show-Usage
    throw "Please provide both -ResourceGroupName and -FunctionAppName."
}

Assert-CommandAvailable -CommandName "dotnet"
Assert-CommandAvailable -CommandName "az"

if (-not (Test-Path -LiteralPath $OutputRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
}

if (-not $SkipAzureLoginCheck) {
    Test-AzureCliLogin
}

if (-not $SkipAppSettingsCheck) {
    $appSettings = Get-FunctionAppSettingsMap `
        -ResourceGroupName $ResourceGroupName `
        -FunctionAppName $FunctionAppName

    Assert-RequiredSqlSettingsExist -SettingsMap $appSettings

    if (-not $SkipSchemaRejectSettingsEnsure) {
        Ensure-SchemaRejectAppSettings `
            -SettingsMap $appSettings `
            -ResourceGroupName $ResourceGroupName `
            -FunctionAppName $FunctionAppName
    }
}
else {
    Write-Host "Skipping Function App settings checks." -ForegroundColor Yellow
}

$projectInfo = Resolve-FunctionProject -RequestedProjectPath $ProjectPath

Write-Host "Resolved project folder: $($projectInfo.ProjectPath)" -ForegroundColor Cyan
Write-Host "Resolved project file:   $($projectInfo.ProjectFile)" -ForegroundColor Cyan

$safeFunctionAppName = $FunctionAppName -replace '[^A-Za-z0-9_.-]', '_'
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"

$publishDir = Join-Path $OutputRoot "func-publish-$safeFunctionAppName-$PID"
$zipPath    = Join-Path $OutputRoot "$safeFunctionAppName-$stamp.zip"

if (Test-Path -LiteralPath $publishDir) {
    Remove-Item -LiteralPath $publishDir -Recurse -Force
}

if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}

try {
    Write-Host "Publishing .NET Function App..." -ForegroundColor Cyan

    Invoke-NativeCommand `
        -ErrorMessage "dotnet publish failed." `
        -ScriptBlock {
            dotnet publish $projectInfo.ProjectFile -c $Configuration -o $publishDir
        }

    $publishedHostJson = Join-Path $publishDir "host.json"
    if (-not (Test-Path -LiteralPath $publishedHostJson -PathType Leaf)) {
        throw "host.json was not found in publish output at '$publishDir'. Refusing to deploy."
    }

    $publishedWorkerConfig = Join-Path $publishDir "worker.config.json"
    if (-not (Test-Path -LiteralPath $publishedWorkerConfig -PathType Leaf)) {
        Write-Host "Warning: worker.config.json was not found in publish output. This may be fine for some project layouts, but double-check the package if deployment behaves strangely." -ForegroundColor Yellow
    }

    Write-Host "Creating ZIP package: $zipPath" -ForegroundColor Cyan

    Push-Location $publishDir
    try {
        $archiveItems = @(Get-ChildItem -Force | Select-Object -ExpandProperty Name)

        if ($archiveItems.Count -eq 0) {
            throw "Publish folder '$publishDir' was empty. Refusing to deploy."
        }

        Compress-Archive -LiteralPath $archiveItems -DestinationPath $zipPath -Force
    }
    finally {
        Pop-Location
    }

    if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf)) {
        throw "ZIP package was not created at '$zipPath'."
    }

    Write-Host "Deploying ZIP package to $FunctionAppName in $ResourceGroupName..." -ForegroundColor Cyan

    Invoke-NativeCommand `
        -ErrorMessage "ZIP deployment failed." `
        -ScriptBlock {
            az functionapp deployment source config-zip `
                --resource-group $ResourceGroupName `
                --name $FunctionAppName `
                --src $zipPath
        }

    Write-Host "Deployment complete." -ForegroundColor Green
    Write-Host "Package: $zipPath" -ForegroundColor Green
}
finally {
    if (-not $KeepPublishFolder -and (Test-Path -LiteralPath $publishDir)) {
        Remove-Item -LiteralPath $publishDir -Recurse -Force
    }
}

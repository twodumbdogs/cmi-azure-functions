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
  - For known environments, the first argument can be an environment name
    instead of explicit -ResourceGroupName and -FunctionAppName values.

.PARAMETER ResourceGroupName
  Resource group containing the target Function App, or a known environment
  name when FunctionAppName is omitted: dev, pre-prod, preprod, qa, or prod.
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

.PARAMETER SchemaRejectsEnabled
  Default value to apply when SchemaRejects__Enabled is missing.

.PARAMETER SchemaRejectsTableName
  Default value to apply when SchemaRejects__TableName is missing.

.PARAMETER SchemaRejectsCommandTimeoutSeconds
  Default value to apply when SchemaRejects__CommandTimeoutSeconds is missing.

.PARAMETER SchemaRejectsWriteMergedPayload
  Default value to apply when SchemaRejects__WriteMergedPayload is missing.

.PARAMETER SchemaRejectsFailOpen
  Default value to apply when SchemaRejects__FailOpen is missing.

.PARAMETER SkipPostAppSettingsPrompt
  Continue directly to publish/deploy after Function App settings are created or verified.

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

    [ValidateSet("true", "false")]
    [string]$SchemaRejectsEnabled = "true",

    [string]$SchemaRejectsTableName = "dbo._NRF_sbSchemaRejects",

    [int]$SchemaRejectsCommandTimeoutSeconds = 30,

    [ValidateSet("true", "false")]
    [string]$SchemaRejectsWriteMergedPayload = "true",

    [ValidateSet("true", "false")]
    [string]$SchemaRejectsFailOpen = "true",

    [switch]$SkipAzureLoginCheck,
    [switch]$SkipAppSettingsCheck,
    [switch]$SkipSchemaRejectSettingsEnsure,
    [switch]$SkipPostAppSettingsPrompt,
    [switch]$KeepPublishFolder
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Show-Usage {
    $scriptName = Split-Path -Leaf $PSCommandPath

    Write-Host ""
    Write-Host "Usage:" -ForegroundColor Cyan
    Write-Host "  .\$scriptName <environment>"
    Write-Host "  .\$scriptName -ResourceGroupName <resource-group> -FunctionAppName <function-app> [-ProjectPath <path>] [-Configuration Debug|Release]"
    Write-Host ""
    Write-Host "Known environments:" -ForegroundColor Cyan
    Write-Host "  dev      -> rg-glogsb-dev-uksouth-001 / func-glogsb-net-dev-uksouth-001"
    Write-Host "  pre-prod -> rg-glogsb-qa-ukwest-001 / func-glogsb-net-qa-ukwest-001"
    Write-Host "  prod     -> not configured yet"
    Write-Host ""
    Write-Host "Aliases:" -ForegroundColor Cyan
    Write-Host "  -ResourceGroupName can also be passed as -ResourceGroup or -rg"
    Write-Host "  -FunctionAppName can also be passed as -FunctionApp or -fa"
    Write-Host ""
    Write-Host "Examples:" -ForegroundColor Cyan
    Write-Host "  .\$scriptName dev"
    Write-Host "  .\$scriptName pre-prod"
    Write-Host "  .\$scriptName -ResourceGroupName ""rg-glogsb-dev-uksouth-001"" -FunctionAppName ""func-glogsb-net-dev-uksouth-001"""
    Write-Host "  .\$scriptName -rg ""rg-glogsb-qa-ukwest-001"" -fa ""func-glogsb-net-qa-ukwest-001"""
    Write-Host "  .\$scriptName -rg ""rg-glogsb-prod-uksouth-001"" -fa ""func-glogsb-net-prod-uksouth-001"" -SkipSchemaRejectSettingsEnsure"
    Write-Host "  .\$scriptName -rg ""rg-glogsb-dev-uksouth-001"" -fa ""func-glogsb-net-dev-uksouth-001"" -SkipPostAppSettingsPrompt"
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
        $accountInfo = Invoke-AzCli {
            az account show --output json
        } | ConvertFrom-Json
        if ($null -eq $accountInfo -or -not $accountInfo.id) {
            throw "No active Azure session found."
        }

        Write-Host "Logged in as $($accountInfo.user.name)" -ForegroundColor Green
    }
    catch {
        Write-Host "No active Azure session found. Launching az login..." -ForegroundColor Yellow
        Invoke-AzCli {
            az login
        } | Out-Null

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

function Invoke-AzCli {
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock
    )

    $previousPythonWarnings = $env:PYTHONWARNINGS
    $warningFilter = "ignore:You are using cryptography on a 32-bit Python.*:UserWarning"

    if ([string]::IsNullOrWhiteSpace($previousPythonWarnings)) {
        $env:PYTHONWARNINGS = $warningFilter
    }
    elseif ($previousPythonWarnings -notlike "*You are using cryptography on a 32-bit Python*") {
        $env:PYTHONWARNINGS = "$previousPythonWarnings,$warningFilter"
    }

    try {
        & $ScriptBlock
    }
    finally {
        if ($null -eq $previousPythonWarnings) {
            Remove-Item Env:PYTHONWARNINGS -ErrorAction SilentlyContinue
        }
        else {
            $env:PYTHONWARNINGS = $previousPythonWarnings
        }
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

    $settingsJson = Invoke-AzCli {
        az functionapp config appsettings list `
            --resource-group $ResourceGroupName `
            --name $FunctionAppName `
            --output json
    }

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

function Get-CodeReferencedAppSettingNames {
    param(
        [Parameter(Mandatory)]
        [string]$ProjectPath
    )

    Write-Host "Scanning code for Function App setting references in $ProjectPath..." -ForegroundColor Cyan

    $settingNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $sourceFiles = Get-ChildItem -LiteralPath $ProjectPath -Recurse -File -Include "*.cs" |
        Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' }

    foreach ($sourceFile in $sourceFiles) {
        $content = Get-Content -LiteralPath $sourceFile.FullName -Raw
        $matches = [regex]::Matches($content, 'Environment\.GetEnvironmentVariable\("([^"]+)"\)')

        foreach ($match in $matches) {
            $settingName = $match.Groups[1].Value
            if ($settingNames.Add($settingName)) {
                Write-Host "  found $settingName" -ForegroundColor DarkCyan
            }
        }
    }

    return @($settingNames | Sort-Object)
}

function Show-AppSettingsScan {
    param(
        [Parameter(Mandatory)]
        [string[]]$SettingNames,

        [Parameter(Mandatory)]
        [hashtable]$SettingsMap
    )

    Write-Host ""
    Write-Host "Code-referenced Function App settings:" -ForegroundColor Cyan

    foreach ($name in $SettingNames) {
        if (Test-AppSettingHasValue -SettingsMap $SettingsMap -Name $name) {
            Write-Host "  OK      $name" -ForegroundColor Green
        }
        elseif ($SettingsMap.ContainsKey($name)) {
            Write-Host "  EMPTY   $name" -ForegroundColor Yellow
        }
        else {
            Write-Host "  MISSING $name" -ForegroundColor Red
        }
    }
}

function Get-MissingAppSettingNames {
    param(
        [Parameter(Mandatory)]
        [string[]]$SettingNames,

        [Parameter(Mandatory)]
        [hashtable]$SettingsMap
    )

    $missingNames = @()
    foreach ($name in $SettingNames) {
        if (-not $SettingsMap.ContainsKey($name)) {
            $missingNames += $name
        }
    }

    return $missingNames
}

function Get-AppSettingsCreationPlan {
    param(
        [Parameter(Mandatory)]
        [string[]]$MissingNames,

        [Parameter(Mandatory)]
        [hashtable]$SettingsMap,

        [Parameter(Mandatory)]
        [ValidateSet("true", "false")]
        [string]$SchemaRejectsEnabled,

        [Parameter(Mandatory)]
        [string]$SchemaRejectsTableName,

        [Parameter(Mandatory)]
        [int]$SchemaRejectsCommandTimeoutSeconds,

        [Parameter(Mandatory)]
        [ValidateSet("true", "false")]
        [string]$SchemaRejectsWriteMergedPayload,

        [Parameter(Mandatory)]
        [ValidateSet("true", "false")]
        [string]$SchemaRejectsFailOpen
    )

    $schemaRejectDefaults = @{
        "SchemaRejects__Enabled"               = $SchemaRejectsEnabled
        "SchemaRejects__TableName"             = $SchemaRejectsTableName
        "SchemaRejects__CommandTimeoutSeconds" = "$SchemaRejectsCommandTimeoutSeconds"
        "SchemaRejects__WriteMergedPayload"    = $SchemaRejectsWriteMergedPayload
        "SchemaRejects__FailOpen"              = $SchemaRejectsFailOpen
    }

    $safeDefaults = @{
        "ServiceBus__MatterTopic"              = "cmi-matter"
        "ServiceBus__ClientTopic"              = "cmi-client"
        "ServiceBus__PayorTopic"               = "cmi-payor"
        "intapp__ibSkipCertificateCheck"       = "false"
    }

    $placeholderNames = @(
        "intapp__ibHost",
        "intapp__ibRuleId",
        "intapp__ibToken"
    )

    $hasSqlConnectionString = Test-AppSettingHasValue -SettingsMap $SettingsMap -Name "Sql__ConnectionString"
    $hasServiceBusConnectionString = Test-AppSettingHasValue -SettingsMap $SettingsMap -Name "service_bus__connectionString"
    $hasServiceBusRbacNamespace = Test-AppSettingHasValue -SettingsMap $SettingsMap -Name "service_bus_RBAC__fullyQualifiedNamespace"

    $create = [ordered]@{}
    $skip = @()

    foreach ($name in $MissingNames) {
        if ($schemaRejectDefaults.ContainsKey($name)) {
            $skip += [pscustomobject]@{
                Name   = $name
                Reason = "handled by the SchemaRejects settings ensure step"
            }
            continue
        }

        if ($safeDefaults.ContainsKey($name)) {
            $create[$name] = $safeDefaults[$name]
            continue
        }

        if ($placeholderNames -contains $name) {
            $create[$name] = "TODO_SET_ME"
            continue
        }

        if (($name -eq "Sql__Server" -or $name -eq "Sql__Database") -and $hasSqlConnectionString) {
            $skip += [pscustomobject]@{
                Name   = $name
                Reason = "not needed because Sql__ConnectionString exists"
            }
            continue
        }

        if ($name -eq "Sql__ConnectionString" -and (Test-AppSettingHasValue -SettingsMap $SettingsMap -Name "Sql__Server") -and (Test-AppSettingHasValue -SettingsMap $SettingsMap -Name "Sql__Database")) {
            $skip += [pscustomobject]@{
                Name   = $name
                Reason = "not needed because Sql__Server and Sql__Database exist"
            }
            continue
        }

        if (($name -eq "service_bus__connectionString" -or $name -eq "service_bus_RBAC__fullyQualifiedNamespace") -and ($hasServiceBusConnectionString -or $hasServiceBusRbacNamespace)) {
            $skip += [pscustomobject]@{
                Name   = $name
                Reason = "not needed because another Service Bus auth setting exists"
            }
            continue
        }

        if ($name -eq "SchemaValidation__Directory") {
            $skip += [pscustomobject]@{
                Name   = $name
                Reason = "optional; code defaults to the packaged Schemas folder"
            }
            continue
        }

        $create[$name] = "TODO_SET_ME"
    }

    [pscustomobject]@{
        Create = $create
        Skip   = $skip
    }
}

function Confirm-CreateMissingAppSettings {
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$SettingsToCreate
    )

    if ($SettingsToCreate.Count -eq 0) {
        return $false
    }

    Write-Host ""
    Write-Host "Missing settings that can be created before deployment:" -ForegroundColor Yellow
    foreach ($name in $SettingsToCreate.Keys) {
        Write-Host "  $name=$($SettingsToCreate[$name])" -ForegroundColor Yellow
    }

    $answer = Read-Host "Create these missing Function App settings now? Type Y to create"
    return ($answer -match '^(?i:y(?:es)?)$')
}

function Add-MissingFunctionAppSettings {
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$FunctionAppName,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$SettingsToCreate
    )

    if ($SettingsToCreate.Count -eq 0) {
        return
    }

    $settingsArgs = @()
    foreach ($name in $SettingsToCreate.Keys) {
        $settingsArgs += "$name=$($SettingsToCreate[$name])"
    }

    Invoke-AzCli {
        az functionapp config appsettings set `
            --resource-group $ResourceGroupName `
            --name $FunctionAppName `
            --settings $settingsArgs `
            --output none
    }

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create missing Function App settings."
    }

    Write-Host "Missing Function App settings created." -ForegroundColor Green
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
        [string]$FunctionAppName,

        [Parameter(Mandatory)]
        [ValidateSet("true", "false")]
        [string]$Enabled,

        [Parameter(Mandatory)]
        [string]$TableName,

        [Parameter(Mandatory)]
        [int]$CommandTimeoutSeconds,

        [Parameter(Mandatory)]
        [ValidateSet("true", "false")]
        [string]$WriteMergedPayload,

        [Parameter(Mandatory)]
        [ValidateSet("true", "false")]
        [string]$FailOpen
    )

    $defaults = [ordered]@{
        "SchemaRejects__Enabled"               = $Enabled
        "SchemaRejects__TableName"             = $TableName
        "SchemaRejects__CommandTimeoutSeconds" = "$CommandTimeoutSeconds"
        "SchemaRejects__WriteMergedPayload"    = $WriteMergedPayload
        "SchemaRejects__FailOpen"              = $FailOpen
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

    Invoke-AzCli {
        az functionapp config appsettings set `
            --resource-group $ResourceGroupName `
            --name $FunctionAppName `
            --settings $settingsArgs `
            --output none
    }

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to add missing SchemaRejects app settings."
    }

    Write-Host "Missing SchemaRejects app settings added." -ForegroundColor Green
}

function Confirm-ContinueAfterAppSettingsCheck {
    param(
        [Parameter(Mandatory)]
        [string]$FunctionAppName
    )

    Write-Host ""
    Write-Host "Function App settings have been created/verified for $FunctionAppName." -ForegroundColor Green
    Write-Host "Review the setting results above before publishing and deploying the ZIP package." -ForegroundColor Yellow

    $answer = Read-Host "Continue with publish and deployment? Type Y to continue"
    return ($answer -match '^(?i:y(?:es)?)$')
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

Assert-CommandAvailable -CommandName "dotnet"
Assert-CommandAvailable -CommandName "az"

if (-not (Test-Path -LiteralPath $OutputRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
}

$projectInfo = Resolve-FunctionProject -RequestedProjectPath $ProjectPath

if (-not $SkipAzureLoginCheck) {
    Test-AzureCliLogin
}

if (-not $SkipAppSettingsCheck) {
    $appSettings = Get-FunctionAppSettingsMap `
        -ResourceGroupName $ResourceGroupName `
        -FunctionAppName $FunctionAppName

    $codeReferencedSettings = Get-CodeReferencedAppSettingNames -ProjectPath $projectInfo.ProjectPath
    Show-AppSettingsScan -SettingNames $codeReferencedSettings -SettingsMap $appSettings

    $missingCodeReferencedSettings = Get-MissingAppSettingNames `
        -SettingNames $codeReferencedSettings `
        -SettingsMap $appSettings

    if ($missingCodeReferencedSettings.Count -gt 0) {
        $creationPlan = Get-AppSettingsCreationPlan `
            -MissingNames $missingCodeReferencedSettings `
            -SettingsMap $appSettings `
            -SchemaRejectsEnabled $SchemaRejectsEnabled `
            -SchemaRejectsTableName $SchemaRejectsTableName `
            -SchemaRejectsCommandTimeoutSeconds $SchemaRejectsCommandTimeoutSeconds `
            -SchemaRejectsWriteMergedPayload $SchemaRejectsWriteMergedPayload `
            -SchemaRejectsFailOpen $SchemaRejectsFailOpen

        if ($creationPlan.Skip.Count -gt 0) {
            Write-Host ""
            Write-Host "Missing settings skipped by default:" -ForegroundColor DarkYellow
            foreach ($skippedSetting in $creationPlan.Skip) {
                Write-Host "  $($skippedSetting.Name) - $($skippedSetting.Reason)" -ForegroundColor DarkYellow
            }
        }

        if (Confirm-CreateMissingAppSettings -SettingsToCreate $creationPlan.Create) {
            Add-MissingFunctionAppSettings `
                -ResourceGroupName $ResourceGroupName `
                -FunctionAppName $FunctionAppName `
                -SettingsToCreate $creationPlan.Create

            foreach ($name in $creationPlan.Create.Keys) {
                $appSettings[$name] = $creationPlan.Create[$name]
            }
        }
        elseif ($creationPlan.Create.Count -gt 0) {
            Write-Host "Missing Function App settings were not created." -ForegroundColor Yellow
        }
        elseif ($creationPlan.Skip.Count -gt 0) {
            Write-Host "No missing settings need to be created before deployment." -ForegroundColor Green
        }
    }

    Assert-RequiredSqlSettingsExist -SettingsMap $appSettings

    if (-not $SkipSchemaRejectSettingsEnsure) {
        Ensure-SchemaRejectAppSettings `
            -SettingsMap $appSettings `
            -ResourceGroupName $ResourceGroupName `
            -FunctionAppName $FunctionAppName `
            -Enabled $SchemaRejectsEnabled `
            -TableName $SchemaRejectsTableName `
            -CommandTimeoutSeconds $SchemaRejectsCommandTimeoutSeconds `
            -WriteMergedPayload $SchemaRejectsWriteMergedPayload `
            -FailOpen $SchemaRejectsFailOpen
    }

    if (-not $SkipPostAppSettingsPrompt) {
        $shouldContinue = Confirm-ContinueAfterAppSettingsCheck -FunctionAppName $FunctionAppName
        if (-not $shouldContinue) {
            Write-Host "Deployment cancelled after Function App settings check." -ForegroundColor Yellow
            return
        }
    }
}
else {
    Write-Host "Skipping Function App settings checks." -ForegroundColor Yellow
}

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
            Invoke-AzCli {
                az functionapp deployment source config-zip `
                    --resource-group $ResourceGroupName `
                    --name $FunctionAppName `
                    --src $zipPath
            }
        }

    Write-Host "Deployment complete." -ForegroundColor Green
    Write-Host "Package: $zipPath" -ForegroundColor Green
}
finally {
    if (-not $KeepPublishFolder -and (Test-Path -LiteralPath $publishDir)) {
        Remove-Item -LiteralPath $publishDir -Recurse -Force
    }
}

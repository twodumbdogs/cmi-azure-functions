param(
    [Parameter(Mandatory)]
    [string]$LeftPath,

    [Parameter(Mandatory)]
    [string]$RightPath,

    [Parameter(Mandatory)]
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

function Test-IsObject {
    param([object]$Value)
    return $Value -is [pscustomobject] -or $Value -is [hashtable]
}

function Test-IsArray {
    param([object]$Value)
    return (
        $Value -is [System.Collections.IEnumerable] -and
        $Value -isnot [string] -and
        $Value -isnot [hashtable] -and
        $Value -isnot [pscustomobject]
    )
}

function Test-IsBlank {
    param([object]$Value)

    if ($null -eq $Value) { return $true }

    if ($Value -is [string]) {
        return [string]::IsNullOrWhiteSpace($Value)
    }

    return $false
}

function Copy-JsonNode {
    param([object]$Node)

    if ($null -eq $Node) { return $null }

    if (Test-IsObject $Node) {
        $copy = [pscustomobject]@{}
        foreach ($p in $Node.PSObject.Properties) {
            $copy | Add-Member -NotePropertyName $p.Name -NotePropertyValue (Copy-JsonNode $p.Value)
        }
        return $copy
    }

    if (Test-IsArray $Node) {
        $items = @()
        foreach ($i in $Node) {
            $items += @(Copy-JsonNode $i)
        }
        return ,$items
    }

    return $Node
}

function Merge-JsonObject {
    param(
        [Parameter(Mandatory)]
        [object]$Left,

        [Parameter(Mandatory)]
        [object]$Right
    )

    foreach ($rightProp in $Right.PSObject.Properties) {
        $name = $rightProp.Name
        $rightValue = $rightProp.Value
        $leftProp = $Left.PSObject.Properties[$name]

        # Property doesn't exist on left → just add it
        if ($null -eq $leftProp) {
            $Left | Add-Member -NotePropertyName $name -NotePropertyValue (Copy-JsonNode $rightValue)
            continue
        }

        $leftValue = $leftProp.Value

        # OBJECT → recurse
        if ((Test-IsObject $leftValue) -and (Test-IsObject $rightValue)) {
            Merge-JsonObject -Left $leftValue -Right $rightValue
            continue
        }

        # ARRAY handling
        if ((Test-IsArray $leftValue) -and (Test-IsArray $rightValue)) {

            if ($rightValue.Count -eq 0) {
                # RIGHT is empty → keep LEFT
                continue
            }
            else {
                # RIGHT has data → overwrite
                $Left.$name = Copy-JsonNode $rightValue
                continue
            }
        }

        # SCALAR handling
        if (Test-IsBlank $rightValue) {
            # RIGHT is blank → keep LEFT
            continue
        }
        else {
            # RIGHT has value → overwrite
            $Left.$name = Copy-JsonNode $rightValue
        }
    }

    return $Left
}

try {
    Write-Host "Reading left JSON:  $LeftPath"
    Write-Host "Reading right JSON: $RightPath"

    $leftObject  = Get-Content $LeftPath  -Raw | ConvertFrom-Json
    $rightObject = Get-Content $RightPath -Raw | ConvertFrom-Json

    $merged = Merge-JsonObject -Left $leftObject -Right $rightObject

    $merged | ConvertTo-Json -Depth 100 | Set-Content $OutputPath -Encoding UTF8

    Write-Host "Merge complete!"
    Write-Host "Output: $OutputPath"
}
catch {
    Write-Error $_.Exception.Message
    throw
}
#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Add an issue to the Project and set its custom field values (idempotent).

.DESCRIPTION
    Adds the issue to the Project (no-op if already present) and sets any of the
    supplied fields: Level, Priority, Phase, Status (single-select) and Estimate
    (number). Single-select values are matched to their option by name.

.PARAMETER Owner
    Project owner (user or org).

.PARAMETER ProjectNumber
    The Project's number.

.PARAMETER Repo
    Repository in 'owner/repo' form (used to build the issue URL).

.PARAMETER IssueNumber
    The issue to place on the board.

.PARAMETER Level
    Single-select value for the Level field (plan|epic|story|task).

.PARAMETER Priority
    Single-select value for the Priority field (P0..P3).

.PARAMETER Phase
    Single-select value for the Phase field.

.PARAMETER Status
    Single-select value for the built-in Status field.

.PARAMETER Estimate
    Numeric value for the Estimate field.

.PARAMETER DryRun
    Show planned actions without applying them.

.EXAMPLE
    ./.agents/skills/gh-issue-tracking-init/scripts/set-project-fields.ps1 -Owner me -ProjectNumber 3 -Repo me/app -IssueNumber 12 -Level story -Priority P1 -Status 'Todo'

.NOTES
    Requires: GitHub CLI (gh) authenticated with the `project` scope.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Owner,

    [Parameter(Mandatory = $true)]
    [int]$ProjectNumber,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[^/]+/[^/]+$')]
    [string]$Repo,

    [Parameter(Mandatory = $true)]
    [int]$IssueNumber,

    [Parameter()][string]$Level,
    [Parameter()][string]$Priority,
    [Parameter()][string]$Phase,
    [Parameter()][string]$Status,
    [Parameter()][int]$Estimate,

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

function Get-JsonProp {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    # Leading comma prevents PowerShell from unrolling an empty array to $null in the pipeline.
    # An explicit $null guard avoids returning a 1-element array wrapping $null (which would
    # break $null -eq $val checks at call sites).
    if ($prop) {
        if ($null -eq $prop.Value) { return $null }
        return , $prop.Value
    }
    return $null
}

Initialize-Auth -DryRun:$DryRun

# Collect requested single-select assignments (only those actually supplied).
# Use $PSBoundParameters.ContainsKey(...) rather than `$null -ne $X` guards:
# an unbound [string] parameter defaults to an empty string, not $null, so the
# $null -ne guard passes spuriously and emits spurious "Field 'X' not found"
# warnings (the Phase/Priority/Status/Level bug reported from the india89 run).
$singleSelect = [ordered]@{}
if ($PSBoundParameters.ContainsKey('Level'))    { $singleSelect['Level'] = $Level }
if ($PSBoundParameters.ContainsKey('Priority')) { $singleSelect['Priority'] = $Priority }
if ($PSBoundParameters.ContainsKey('Phase'))    { $singleSelect['Phase'] = $Phase }
if ($PSBoundParameters.ContainsKey('Status'))   { $singleSelect['Status'] = $Status }
$hasEstimate = $PSBoundParameters.ContainsKey('Estimate')

$issueUrl = "https://github.com/$Repo/issues/$IssueNumber"

if ($DryRun) {
    $planned = @()
    $planned += ($singleSelect.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" })
    if ($hasEstimate) { $planned += "Estimate=$Estimate" }
    Write-DryRun "Would add issue #$IssueNumber to project #$ProjectNumber and set: $(if ($planned.Count) { $planned -join ', ' } else { '(no fields)' })."
    return
}

# Resolve project node id and field metadata.
$project = Invoke-GhJson project view $ProjectNumber --owner $Owner --format json
$projectId = $project.id

$fieldData = Invoke-GhJson project field-list $ProjectNumber --owner $Owner --format json --limit 200
$fields = Get-JsonProp $fieldData 'fields'
if ($null -eq $fields) { $fields = $fieldData }

# Add the issue to the project (returns the item; already-added issues return the existing item).
Write-Step "Adding issue #$IssueNumber to project #$ProjectNumber..."
$item = Invoke-GhJson project item-add $ProjectNumber --owner $Owner --url $issueUrl --format json
$itemId = $item.id

function Set-SingleSelect {
    param([string]$FieldName, [string]$OptionName)
    $field = @($fields | Where-Object { $_.name -eq $FieldName }) | Select-Object -First 1
    if (-not $field) { Write-Warning "Field '$FieldName' not found on project; skipping."; return }
    $options = Get-JsonProp $field 'options'
    $opt = @($options | Where-Object { $_.name -eq $OptionName }) | Select-Object -First 1
    if (-not $opt) { Write-Warning "Option '$OptionName' not found for field '$FieldName'; skipping."; return }
    Invoke-Gh project item-edit --id $itemId --project-id $projectId --field-id $field.id --single-select-option-id $opt.id | Out-Null
    Write-Ok "Set $FieldName = $OptionName."
}

foreach ($entry in $singleSelect.GetEnumerator()) {
    Set-SingleSelect -FieldName $entry.Key -OptionName $entry.Value
}

if ($hasEstimate) {
    $field = @($fields | Where-Object { $_.name -eq 'Estimate' }) | Select-Object -First 1
    if ($field) {
        Invoke-Gh project item-edit --id $itemId --project-id $projectId --field-id $field.id --number $Estimate | Out-Null
        Write-Ok "Set Estimate = $Estimate."
    }
    else { Write-Warning "Field 'Estimate' not found on project; skipping." }
}

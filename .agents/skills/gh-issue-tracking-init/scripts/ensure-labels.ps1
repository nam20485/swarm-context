#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Ensure the canonical gh-issue-tracking label taxonomy exists in a repository.

.DESCRIPTION
    Idempotently creates/updates the canonical label set (Level, Priority, Area,
    and cross-cutting Status labels) defined in labels.json. Delegates to the
    vendored import-labels.ps1 (colocated in this skill's scripts/ directory)
    which creates missing labels and updates color/description when they differ.

    Workflow state (Todo / In Progress / In Review / Done) is tracked by the
    Project Status field, not by labels, so it is intentionally absent here.

.PARAMETER Repo
    Target repository in 'owner/repo' form.

.PARAMETER LabelsFile
    Path to the labels JSON (default: assets/labels.json at the skill root).

.PARAMETER DryRun
    Show planned changes without applying them.

.EXAMPLE
    ./.agents/skills/gh-issue-tracking-init/scripts/ensure-labels.ps1 -Repo owner/repo -DryRun

.NOTES
    Requires: GitHub CLI (gh) authenticated against the target repo.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[^/]+/[^/]+$')]
    [string]$Repo,

    [Parameter()]
    [string]$LabelsFile = (Join-Path (Split-Path -Parent $PSScriptRoot) 'assets/labels.json'),

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

if (-not (Test-Path -LiteralPath $LabelsFile)) {
    throw "Labels file not found: $LabelsFile"
}

$importLabels = Join-Path $PSScriptRoot 'import-labels.ps1'
if (-not (Test-Path -LiteralPath $importLabels)) {
    throw "Required helper not found: $importLabels"
}

Write-Step "Ensuring canonical labels on $Repo (source: $LabelsFile)"
& $importLabels -Repo $Repo -LabelsFile $LabelsFile -DryRun:$DryRun

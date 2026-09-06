#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Idempotently create or update a single hierarchy issue from a template body.

.DESCRIPTION
    Looks for an existing open/closed issue with an exact title match:
      - not found -> creates the issue (title, body, labels, milestone, assignees)
      - found     -> updates labels + milestone (and body only when -UpdateBody is set)

    The caller (the hierarchy-creation skill) is responsible for filling the
    template body and computing the numbered title (e.g. "Epic 1: Inference").
    On success the issue NUMBER is written to stdout so the caller can capture it
    for sub-issue linking and Project field assignment.

.PARAMETER Repo
    Target repository in 'owner/repo' form.

.PARAMETER Title
    Full issue title, including the numbered prefix (e.g. "Story 1.2: Streaming API").

.PARAMETER Body
    Issue body text. Mutually exclusive with -BodyFile.

.PARAMETER BodyFile
    Path to a file containing the issue body. Mutually exclusive with -Body.

.PARAMETER Labels
    Label names to apply (e.g. epic, P1, area/ai).

.PARAMETER Milestone
    Milestone title to assign (must already exist).

.PARAMETER Assignee
    GitHub usernames to assign.

.PARAMETER UpdateBody
    When updating an existing issue, also overwrite its body. Off by default so
    re-runs don't clobber manual edits.

.PARAMETER DryRun
    Show planned actions without applying them.

.EXAMPLE
    ./.agents/skills/gh-issue-tracking-init/scripts/ensure-issue.ps1 -Repo owner/repo -Title 'Epic 1: Core' -BodyFile ./epic1.md -Labels epic,P1 -Milestone MVP

.NOTES
    Requires: GitHub CLI (gh) authenticated against the target repo.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[^/]+/[^/]+$')]
    [string]$Repo,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Title,

    [Parameter()]
    [string]$Body,

    [Parameter()]
    [string]$BodyFile,

    [Parameter()]
    [string[]]$Labels,

    [Parameter()]
    [string]$Milestone,

    [Parameter()]
    [string[]]$Assignee,

    [switch]$UpdateBody,

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

if ($Body -and $BodyFile) {
    throw 'Specify only one of -Body or -BodyFile.'
}
if ($BodyFile -and -not (Test-Path -LiteralPath $BodyFile)) {
    throw "Body file not found: $BodyFile"
}

Initialize-Auth -DryRun:$DryRun

$existingNumber = Find-IssueNumberByTitle -Repo $Repo -Title $Title

if ($existingNumber) {
    # --- Update path --------------------------------------------------------
    Write-Step "Issue #$existingNumber matches '$Title' — updating."
    if ($DryRun) {
        Write-DryRun "Would edit issue #$existingNumber (labels: $($Labels -join ', ')$(if ($Milestone) { "; milestone: $Milestone" })$(if ($UpdateBody) { '; body' }))."
        Write-Output $existingNumber
        return
    }
    $editArgs = @('issue', 'edit', $existingNumber, '--repo', $Repo)
    foreach ($l in $Labels) { $editArgs += @('--add-label', $l) }
    if ($null -ne $Milestone) { $editArgs += @('--milestone', $Milestone) }
    if ($UpdateBody) {
        if ($BodyFile) { $editArgs += @('--body-file', $BodyFile) }
        elseif ($null -ne $Body) { $editArgs += @('--body', $Body) }
    }
    Invoke-Gh @editArgs | Out-Null
    Write-Ok "Updated issue #$existingNumber."
    Write-Output $existingNumber
    return
}

# --- Create path ------------------------------------------------------------
Write-Step "No issue titled '$Title' — creating."
if ($DryRun) {
    Write-DryRun "Would create issue '$Title' (labels: $($Labels -join ', ')$(if ($Milestone) { "; milestone: $Milestone" }))."
    return
}

$createArgs = @('issue', 'create', '--repo', $Repo, '--title', $Title)
if ($BodyFile) { $createArgs += @('--body-file', $BodyFile) }
else { $createArgs += @('--body', ($Body ?? '')) }
foreach ($l in $Labels) { $createArgs += @('--label', $l) }
if ($null -ne $Milestone) { $createArgs += @('--milestone', $Milestone) }
foreach ($a in $Assignee) { $createArgs += @('--assignee', $a) }

$createOut = Invoke-Gh @createArgs
$urlLine = ($createOut | Where-Object { $_ -match '/issues/\d+' } | Select-Object -Last 1)
if (-not $urlLine) { $urlLine = ($createOut | Select-Object -Last 1) }
$url = ([string]$urlLine).Trim()
if ($url -match '/issues/(\d+)\s*$') {
    $number = [int]$Matches[1]
} else {
    throw "Failed to parse issue number from output: $url"
}
Write-Ok "Created issue #$number ($url)"
Write-Output $number

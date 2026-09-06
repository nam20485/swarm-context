#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Record that one issue is blocked by another (idempotent).

.DESCRIPTION
    Uses the GitHub issue-dependencies REST API:
        POST /repos/{owner}/{repo}/issues/{issue}/dependencies/blocked_by  { "issue_id": <blocking DB id> }
    The API keys off the blocking issue's numeric database id (not its number),
    which this script resolves automatically. If the relationship already exists,
    it is skipped.

.PARAMETER Repo
    Target repository in 'owner/repo' form.

.PARAMETER IssueNumber
    The issue that is blocked.

.PARAMETER BlockedByNumber
    The issue that blocks it.

.PARAMETER DryRun
    Show planned actions without applying them.

.EXAMPLE
    ./.agents/skills/gh-issue-tracking-init/scripts/set-dependency.ps1 -Repo owner/repo -IssueNumber 14 -BlockedByNumber 12

.NOTES
    Requires: GitHub CLI (gh) authenticated against the target repo.
    Creating dependencies too quickly may trigger secondary rate limiting.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[^/]+/[^/]+$')]
    [string]$Repo,

    [Parameter(Mandatory = $true)]
    [int]$IssueNumber,

    [Parameter(Mandatory = $true)]
    [int]$BlockedByNumber,

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

Initialize-Auth -DryRun:$DryRun

if ($DryRun) {
    Write-DryRun "Would mark #$IssueNumber as blocked by #$BlockedByNumber. (dry-run skips discovery; relationship may already exist)"
    return
}

# Idempotency: is the relationship already recorded?
$already = $false
try {
    $blockers = Invoke-GhJson api "repos/$Repo/issues/$IssueNumber/dependencies/blocked_by" --paginate
    if ($blockers) { $already = [bool](@($blockers | Where-Object { [int]$_.number -eq $BlockedByNumber }).Count) }
}
catch {
    throw "Failed to list existing dependencies of #${IssueNumber} during discovery: $($_.Exception.Message)"
}

if ($already) {
    Write-Skip "#$IssueNumber is already blocked by #$BlockedByNumber."
    return
}

$blockingId = Get-IssueDbId -Repo $Repo -Number $BlockedByNumber
Write-Step "Marking #$IssueNumber as blocked by #$BlockedByNumber (id $blockingId)..."
Invoke-Gh api "repos/$Repo/issues/$IssueNumber/dependencies/blocked_by" -X POST -F "issue_id=$blockingId" | Out-Null
Write-Ok "#$IssueNumber is now blocked by #$BlockedByNumber."

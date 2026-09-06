#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Link a child issue as a sub-issue of a parent issue (idempotent).

.DESCRIPTION
    Uses the GitHub sub-issues REST API:
        POST /repos/{owner}/{repo}/issues/{parent}/sub_issues  { "sub_issue_id": <child DB id> }
    The API keys off the child issue's numeric database id (not its number), which
    this script resolves automatically. If the child is already a sub-issue of the
    parent, the operation is skipped.

.PARAMETER Repo
    Target repository in 'owner/repo' form.

.PARAMETER ParentNumber
    Issue number of the parent (e.g. the epic).

.PARAMETER ChildNumber
    Issue number of the child to attach (e.g. a story).

.PARAMETER DryRun
    Show planned actions without applying them.

.EXAMPLE
    ./.agents/skills/gh-issue-tracking-init/scripts/link-sub-issue.ps1 -Repo owner/repo -ParentNumber 10 -ChildNumber 12

.NOTES
    Requires: GitHub CLI (gh) authenticated against the target repo. The sub-issue
    must belong to the same repository owner as the parent.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[^/]+/[^/]+$')]
    [string]$Repo,

    [Parameter(Mandatory = $true)]
    [int]$ParentNumber,

    [Parameter(Mandatory = $true)]
    [int]$ChildNumber,

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

Initialize-Auth -DryRun:$DryRun

if ($DryRun) {
    Write-DryRun "Would add #$ChildNumber as a sub-issue of #$ParentNumber. (dry-run skips discovery; relationship may already exist)"
    return
}

# Idempotency: is the child already a sub-issue of the parent?
$already = $false
try {
    $subs = Invoke-GhJson api "repos/$Repo/issues/$ParentNumber/sub_issues" --paginate
    if ($subs) { $already = [bool](@($subs | Where-Object { [int]$_.number -eq $ChildNumber }).Count) }
}
catch {
    throw "Failed to list existing sub-issues of #${ParentNumber} during discovery: $($_.Exception.Message)"
}

if ($already) {
    Write-Skip "#$ChildNumber is already a sub-issue of #$ParentNumber."
    return
}

$childId = Get-IssueDbId -Repo $Repo -Number $ChildNumber
Write-Step "Adding #$ChildNumber (id $childId) as a sub-issue of #$ParentNumber..."
Invoke-Gh api "repos/$Repo/issues/$ParentNumber/sub_issues" -X POST -F "sub_issue_id=$childId" | Out-Null
Write-Ok "Linked #$ChildNumber under #$ParentNumber."

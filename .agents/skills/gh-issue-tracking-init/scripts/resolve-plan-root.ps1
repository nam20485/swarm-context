#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Resolve the plan anchor for a run: which Plan issue the work attaches to,
    and the next repo-wide epic number.

.DESCRIPTION
    Read-only resolution called once at the top of a composed run (before any
    issue creation), primarily for feature-campaign (feature-list) sources:

      1. Lists OPEN issues labeled 'plan' (candidate plan roots).
      2. continue-existing + >= 1 open plan -> target = newest by creation
         (logged when several exist); CreatePlan = false.
      3. continue-existing + 0 open plans  -> CreatePlan = true (nothing to
         continue; closed plan roots are finished campaigns, never continued).
      4. new-feature-plan                  -> CreatePlan = true (always).
      5. NextEpicNumber: max 'Epic <N>:' title prefix over ALL issues
         repo-wide (open + closed) + 1, minimum 1 — epic numbering continues
         repo-wide across all plans, so no two epics ever share an N.

    Output contract (matches ensure-project.ps1): exactly ONE machine-readable
    JSON line on the stdout success stream via Write-Output; all Write-* status
    lines go to host streams (human-only). Example:

        {"Mode":"continue-existing","PlanNumber":42,"PlanTitle":"Plan: Support Assistant","CreatePlan":false,"NextEpicNumber":8}

    PlanNumber/PlanTitle are null when CreatePlan is true (the Plan issue does
    not exist yet; the caller creates it and owns its title).

    Read-only: never creates, edits, or links anything. Concurrent campaigns
    can race the max-epic scan (read-then-create is not atomic) — sequence
    concurrent runs rather than running them in parallel.

.PARAMETER Repo
    Target repository in 'owner/repo' form.

.PARAMETER Mode
    'continue-existing' (default) — attach to the newest open plan root when
    one exists, else create a new Plan issue.
    'new-feature-plan' — always create a new wrapper Plan issue.
    This default IS the skill constant DEFAULT_EXISTING_PLAN_MODE; SKILL.md
    documents it by name and must stay in sync with this script. The mode
    applies ONLY to feature-list plan sources — plan-doc sources match their
    plan issue by title and ignore the mode.

.PARAMETER DryRun
    Announce what would be resolved and exit WITHOUT any gh call.

.EXAMPLE
    ./.agents/skills/gh-issue-tracking-init/scripts/resolve-plan-root.ps1 -Repo owner/repo -Mode continue-existing

.NOTES
    Requires: GitHub CLI (gh) authenticated against the target repo.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[^/]+/[^/]+$')]
    [string]$Repo,

    [Parameter()]
    [ValidateSet('continue-existing', 'new-feature-plan')]
    [string]$Mode = 'continue-existing',   # DEFAULT_EXISTING_PLAN_MODE — single source of truth

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

if ($DryRun) {
    # Announce + exit with ZERO gh calls (auth check included), per contract.
    Write-DryRun "Would resolve the plan anchor for $Repo (mode '$Mode'): list open 'plan'-labeled issues, target the newest by creation in continue-existing mode, and scan repo-wide 'Epic <N>:' titles (open+closed) for the next epic number."
    return
}

Initialize-Auth

function Get-OpenPlanIssues {
    <#.SYNOPSIS List OPEN issues labeled 'plan' (candidate plan roots) via paginated REST.#>
    param(
        [Parameter(Mandatory = $true)][string]$Repo
    )
    # REST issues endpoint (paginated), not `gh issue list --search`, to stay
    # off the GraphQL Search API rate limit (same rationale as
    # Find-IssueNumberByTitle in common.ps1).
    $page = 1
    $found = @()
    while ($true) {
        $batch = Invoke-GhJson api "repos/$Repo/issues?state=open&labels=plan&per_page=100&page=$page"
        if (-not $batch) { break }
        # Under Set-StrictMode -Version Latest, property access on deserialized
        # JSON must go through PSObject.Properties guards (see
        # Find-IssueNumberByTitle); PRs are excluded because the REST issues
        # endpoint returns both issues and pull requests.
        $candidates = @($batch | Where-Object {
                $null -ne $_ `
                -and $null -ne $_.PSObject.Properties['number'] `
                -and $null -ne $_.PSObject.Properties['title'] `
                -and $null -ne $_.PSObject.Properties['created_at'] `
                -and $null -eq $_.PSObject.Properties['pull_request']
            })
        foreach ($m in $candidates) {
            $found += [pscustomobject]@{
                Number    = [int]$m.PSObject.Properties['number'].Value
                Title     = [string]$m.title
                CreatedAt = [datetime]$m.created_at
            }
        }
        if (@($batch).Count -lt 100) { break }
        $page++
    }
    return $found
}

function Get-NextEpicNumber {
    <#.SYNOPSIS Max 'Epic <N>:' title prefix across ALL issues (open+closed) repo-wide, +1 (minimum 1).#>
    param(
        [Parameter(Mandatory = $true)][string]$Repo
    )
    $max = 0
    $page = 1
    while ($true) {
        $batch = Invoke-GhJson api "repos/$Repo/issues?state=all&per_page=100&page=$page"
        if (-not $batch) { break }
        foreach ($i in @($batch)) {
            if ($null -eq $i -or $null -ne $i.PSObject.Properties['pull_request']) { continue }
            $titleProp = $i.PSObject.Properties['title']
            if ($null -eq $titleProp) { continue }
            if ($titleProp.Value -match '^Epic (\d+):') {
                $n = [int]$Matches[1]
                if ($n -gt $max) { $max = $n }
            }
        }
        if (@($batch).Count -lt 100) { break }
        $page++
    }
    return $max + 1
}

# --- Resolve the plan anchor -------------------------------------------------
$openPlans = @(Get-OpenPlanIssues -Repo $Repo)

$planNumber = $null
$planTitle = $null
$createPlan = $false

if ($Mode -eq 'new-feature-plan') {
    $createPlan = $true
    Write-Step "Mode 'new-feature-plan': a new wrapper Plan issue will be created ($($openPlans.Count) open plan issue(s) already exist)."
}
elseif ($openPlans.Count -ge 1) {
    $newest = $openPlans | Sort-Object -Property { $_.CreatedAt } -Descending | Select-Object -First 1
    if ($openPlans.Count -gt 1) {
        Write-Step "Multiple open plan roots found ($($openPlans.Count)); targeting the newest by creation: #$($newest.Number) '$($newest.Title)'."
    }
    else {
        Write-Step "Continuing existing plan root #$($newest.Number) '$($newest.Title)'."
    }
    $planNumber = [int]$newest.Number
    $planTitle = [string]$newest.Title
}
else {
    $createPlan = $true
    Write-Step "Mode 'continue-existing' but no open 'plan'-labeled issue exists (closed plan roots are finished campaigns, never continued) — a new Plan issue will be created."
}

# --- Resolve the next repo-wide epic number ----------------------------------
$nextEpicNumber = Get-NextEpicNumber -Repo $Repo
Write-Step "Next repo-wide epic number: $nextEpicNumber."

# --- Emit the machine-readable anchor on stdout (single JSON line) -----------
# (Host-stream Write-* above are human-readable status; this is the
# machine-readable contract, matching ensure-project.ps1 / ensure-issue.ps1.)
$anchor = [pscustomobject]@{
    Mode           = $Mode
    PlanNumber     = $planNumber
    PlanTitle      = $planTitle
    CreatePlan     = $createPlan
    NextEpicNumber = $nextEpicNumber
}
Write-Output ($anchor | ConvertTo-Json -Compress)

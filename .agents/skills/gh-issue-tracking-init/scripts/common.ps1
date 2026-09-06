#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Shared helpers for the gh-issue-tracking-init operation scripts.

.DESCRIPTION
    Dot-source this file from each operation script:

        . (Join-Path $PSScriptRoot 'common.ps1')

    It provides GitHub CLI auth bootstrap, a single wrapper around `gh`
    (so calls are mockable in Pester), owner/repo parsing, and the id
    lookups required by the sub-issues and issue-dependencies REST APIs
    (both of which key off the issue's numeric database id, not its number).

    This skill's scripts/ directory is self-contained: common-auth.ps1,
    import-labels.ps1, and create-milestones.ps1 are vendored here (copied
    from the repository root's scripts/) so the skill has no dependency on
    the parent scripts/ directory.

.NOTES
    Requires: PowerShell 7+, GitHub CLI (gh) authenticated against the target repo.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# common-auth.ps1 is vendored alongside this file so the skill is self-contained.
$commonAuth = Join-Path $PSScriptRoot 'common-auth.ps1'
if (Test-Path -LiteralPath $commonAuth) { . $commonAuth }

function Assert-GhCli {
    <#.SYNOPSIS Throw unless the gh CLI is on PATH.#>
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw "Required command 'gh' not found in PATH. Install the GitHub CLI first."
    }
}

function Initialize-Auth {
    <#.SYNOPSIS Ensure the gh CLI is authenticated (delegates to Initialize-GitHubAuth when available).#>
    [CmdletBinding()]
    param([switch]$DryRun)
    Assert-GhCli
    if (Get-Command Initialize-GitHubAuth -ErrorAction SilentlyContinue) {
        Initialize-GitHubAuth -DryRun:$DryRun
        return
    }
    & gh auth status 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning 'GitHub CLI is not authenticated. Run: gh auth login'
    }
}

function Initialize-LogFile {
    <#
    .SYNOPSIS
        Create the per-run forensic logfile and record a repo-metadata header.

    .DESCRIPTION
        Call once at the very start of a composed orchestration run. The logfile
        path is stored in $env:GHIT_LOG_FILE so every subsequently dot-sourced op
        script (each with its own $script: scope) writes to the same file via
        Write-Log. The file is created under $RepoRoot with a name of the form

            gh-init-<slug>-<UTC-timestamp>.log

        and begins with a metadata header recording the repository identity, the
        working-copy location, the checked-out git rev and ref, the skill's own
        directory, and the OS/PowerShell version — everything needed for
        post-execution forensics.

        Re-initializing in the same process starts a new timestamped file and
        re-points $env:GHIT_LOG_FILE at it.

        When $RepoRoot does not exist, throws. When git is unavailable or the
        directory is not a git repo, the rev/ref lines are recorded as '(unknown)'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepoSlug,
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [string]$Repo
    )
    if (-not (Test-Path -LiteralPath $RepoRoot -PathType Container)) {
        throw "RepoRoot does not exist or is not a directory: $RepoRoot"
    }
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    # Sanitize the slug for filename safety (allow A–Z a–z 0–9 . _ -; replace the rest).
    $safeSlug = $RepoSlug -replace '[^A-Za-z0-9._-]', '-'
    $fileName = "gh-init-$safeSlug-$stamp.log"
    $absRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
    $path = Join-Path $absRoot $fileName

    # Gather git metadata defensively — never let a missing git or non-repo abort the run.
    $rev = '(unknown)'
    $ref = '(unknown)'
    if (Get-Command git -ErrorAction SilentlyContinue) {
        try {
            $r = & git -C $absRoot rev-parse --short HEAD 2>$null
            if ($LASTEXITCODE -eq 0 -and $r) { $rev = ($r | Out-String).Trim() }
        } catch { }
        try {
            $f = & git -C $absRoot symbolic-ref --short HEAD 2>$null
            if ($LASTEXITCODE -eq 0 -and $f) { $ref = ($f | Out-String).Trim() }
        } catch { }
    }

    $repoLabel = if ($Repo) { $Repo } else { '(unspecified)' }
    # $PSVersionTable is a hashtable, so PSObject.Properties doesn't see its keys;
    # read defensively under Set-StrictMode via try/catch.
    $os = '(unknown)'
    try { if ($PSVersionTable.OS) { $os = [string]$PSVersionTable.OS } } catch { }
    $psVer = '(unknown)'
    try { if ($PSVersionTable.PSVersion) { $psVer = $PSVersionTable.PSVersion.ToString() } } catch { }

    $header = @(
        "# gh-issue-tracking-init run: $stamp (UTC)",
        "# Repository : $repoLabel",
        "# Local path : $absRoot",
        "# Git rev    : $rev",
        "# Git ref    : $ref",
        "# Script dir : $PSScriptRoot",
        "# OS/PS      : $os / PowerShell $psVer",
        ''
    )
    $header | Set-Content -LiteralPath $path -Encoding UTF8

    $env:GHIT_LOG_FILE = $path
    return $path
}

function Write-Log {
    <#
    .SYNOPSIS
        Append one timestamped, operation-tagged line to the forensic logfile.

    .DESCRIPTION
        Silent no-op when Initialize-LogFile has not run (no $env:GHIT_LOG_FILE),
        so op scripts and helpers can call it unconditionally without checking.
        Each line: "<HH:mm:ss.fffZ> [<Op>] <Message>".
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Op = 'general'
    )
    $path = $env:GHIT_LOG_FILE
    if (-not $path) { return }
    $ts = (Get-Date).ToUniversalTime().ToString('HH:mm:ss.fffZ')
    $line = "$ts [$Op] $Message"
    # Add-Content is atomic enough for append-from-a-single-process forensics;
    # use a try/catch so a transiently-unwritable path never aborts the run.
    try {
        Add-Content -LiteralPath $path -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch {
        # Intentionally swallowed: logging must never break the actual work.
    }
}

function Invoke-Gh {
    <#.SYNOPSIS Central wrapper around `gh` so every call is mockable in tests. Throws on non-zero exit.#>
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GhArgs)
    # stdout is captured for the caller; stderr flows to the console so it is not
    # merged into (and corrupting) JSON output.
    $cmd = if ($GhArgs) { $GhArgs -join ' ' } else { '' }
    Write-Log -Op 'gh' -Message "INVOKING: gh $cmd"
    $output = & gh @GhArgs
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        Write-Log -Op 'gh' -Message "FAILED (exit $code): gh $cmd"
        throw "gh $cmd failed (exit $code). See gh output above."
    }
    Write-Log -Op 'gh' -Message "OK (exit 0): gh $cmd"
    return $output
}

function Invoke-GhJson {
    <#.SYNOPSIS Invoke-Gh and parse JSON stdout into objects.#>
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GhArgs)
    $raw = Invoke-Gh @GhArgs
    if (-not $raw) { return $null }
    return ($raw | Out-String | ConvertFrom-Json)
}

function Get-RepoParts {
    <#.SYNOPSIS Split an 'owner/repo' string into Owner/Name.#>
    param([Parameter(Mandatory = $true)][string]$Repo)
    if ($Repo -notmatch '^[^/]+/[^/]+$') {
        throw "Repo must be in 'owner/repo' form; got: $Repo"
    }
    $parts = $Repo.Split('/', 2)
    return [pscustomobject]@{ Owner = $parts[0]; Name = $parts[1] }
}

function Get-IssueDbId {
    <#.SYNOPSIS Return an issue's numeric database id (required by sub-issues + dependencies APIs), not its number.#>
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][int]$Number
    )
    $rawOutput = Invoke-Gh api "repos/$Repo/issues/$Number" --jq '.id'
    if ($rawOutput -match '^\d+$') {
        $rawId = $Matches[0]
    } else {
        throw "Failed to parse numeric database ID for issue #$Number in repo '$Repo'. Raw output: '$rawOutput'"
    }
    # [long], not [int]: GitHub global issue database IDs now exceed Int32.MaxValue (2,147,483,647).
    # Casting to [int] throws "Value was either too large or too small for an Int32" on modern repos.
    return [long]$rawId
}

function Find-IssueNumberByTitle {
    <#.SYNOPSIS Exact-title lookup across open+closed issues (for idempotent create/update). Returns [int] or $null.#>
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string]$Title
    )
    # Resolve via the REST issues endpoint (paginated) rather than `gh issue list --search`,
    # which routes through the GraphQL Search API and is far more susceptible to rate limiting.
    $page = 1
    while ($true) {
        $batch = Invoke-GhJson api "repos/$Repo/issues?state=all&per_page=100&page=$page"
        if (-not $batch) { break }
        # Match by exact title, excluding pull requests (the REST issues endpoint
        # returns both issues and PRs, and a PR sharing an issue's title would
        # otherwise shadow it).
        # Under Set-StrictMode -Version Latest, accessing a non-existent property
        # (e.g. `title` or `pull_request`) throws PropertyNotFoundException, so
        # guard against null elements and verify property existence via the
        # PSObject.Properties collection before reading the value.
        $match = @($batch | Where-Object {
                $null -ne $_ `
                -and $null -ne $_.PSObject.Properties['title'] `
                -and $_.PSObject.Properties['title'].Value -eq $Title `
                -and $null -eq $_.PSObject.Properties['pull_request']
            }) | Select-Object -First 1
        if ($match) { return [int]$match.number }
        if (@($batch).Count -lt 100) { break }
        $page++
    }
    return $null
}

function Write-Step { param([string]$Message) Write-Host $Message -ForegroundColor Cyan; Write-Log -Op 'STEP' -Message $Message }
function Write-DryRun { param([string]$Message) Write-Host "[dry-run] $Message" -ForegroundColor Yellow; Write-Log -Op 'DRYRUN' -Message $Message }
function Write-Ok { param([string]$Message) Write-Host $Message -ForegroundColor Green; Write-Log -Op 'OK' -Message $Message }
function Write-Skip { param([string]$Message) Write-Host $Message -ForegroundColor DarkGray; Write-Log -Op 'SKIP' -Message $Message }

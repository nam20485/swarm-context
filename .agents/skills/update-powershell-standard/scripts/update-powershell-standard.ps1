#Requires -Version 7.0
<#
.SYNOPSIS
    Refreshes the vendored PowerShell Engineer Standard rules hierarchy from upstream.

.DESCRIPTION
    Fetches the monolithic upstream AGENTS.md from powershellengineer.com, parses its
    version, compares that against the version recorded in .agents/rules/powershell.md,
    and - when the version changed or -Force was given - splits the document into topic
    files under .agents/rules/powershell/ and stamps the new version into the index.

    Topic files are generated artifacts. Never hand-edit them: every file carries a
    generated-by header, is replaced wholesale on refresh, and house-specific content
    belongs only in the hand-maintained index .agents/rules/powershell.md.

.PARAMETER SourceUrl
    Upstream AGENTS.md URL. Default: https://www.powershellengineer.com/AGENTS.md

.PARAMETER SourceFile
    Local markdown file to split instead of fetching the URL. Mutually exclusive with
    the fetch path in practice; used by Pester tests and offline refreshes.

.PARAMETER RepoRoot
    Repository root that owns .agents/rules/. Default: four levels above this script
    (<repo>/.agents/skills/update-powershell-standard/scripts).

.PARAMETER CheckOnly
    Compare versions and report whether an update is available, without writing files.

.PARAMETER Force
    Re-run the split even when the upstream version is unchanged (same-version edits
    upstream, or repairing a corrupted tree).

.INPUTS
    None.

.OUTPUTS
    PSEStandard.RefreshSummary - one summary object describing what happened.

.EXAMPLE
    pwsh .agents/skills/update-powershell-standard/scripts/update-powershell-standard.ps1

    Fetches upstream; no-ops when the recorded version matches, otherwise regenerates
    the topic files and stamps the new version into the index.

.EXAMPLE
    pwsh .agents/skills/update-powershell-standard/scripts/update-powershell-standard.ps1 -CheckOnly

    Reports whether an upstream update is available without writing anything.

.EXAMPLE
    pwsh .agents/skills/update-powershell-standard/scripts/update-powershell-standard.ps1 -SourceFile ./fixture.md -RepoRoot /tmp/fake-repo

    Regenerates from a local fixture into a scratch repo tree (how the Pester suite
    exercises the script without network access).

.NOTES
    Upstream content is MIT-licensed (Jim Tyler, powershellengineer.com). Requires
    network access unless -SourceFile is supplied.
#>

[CmdletBinding(SupportsShouldProcess)]
[OutputType('PSEStandard.RefreshSummary')]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $SourceUrl = 'https://www.powershellengineer.com/AGENTS.md',

    [Parameter()]
    [ValidateScript({
        if (-not (Test-Path -LiteralPath $_ -PathType Leaf)) {
            throw "SourceFile not found: $_"
        }
        $true
    })]
    [string] $SourceFile,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $RepoRoot,

    [Parameter()]
    [switch] $CheckOnly,

    [Parameter()]
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Section -> topic-file map and topic titles.
# House convention: sections keep their upstream numbers inside the topic files,
# grouped by when an agent needs them. If upstream adds/removes a top-level
# section, the script fails loudly so a human updates this map deliberately.
# ---------------------------------------------------------------------------
$sectionFileMap = @{
    '0'                 = '00-non-negotiables.md'
    '1'                 = '01-function-authoring.md'
    '2'                 = '01-function-authoring.md'
    '3'                 = '01-function-authoring.md'
    '4'                 = '01-function-authoring.md'
    '5'                 = '02-pipeline-errors-safety.md'
    '6'                 = '02-pipeline-errors-safety.md'
    '7'                 = '02-pipeline-errors-safety.md'
    '8'                 = '03-help-and-prose.md'
    '19'                = '03-help-and-prose.md'
    '9'                 = '04-testing-pester.md'
    '10'                = '05-modules-packaging.md'
    '14'                = '05-modules-packaging.md'
    '18'                = '05-modules-packaging.md'
    '11'                = '06-performance.md'
    '12'                = '07-security.md'
    '13'                = '08-platform-style-encoding.md'
    '16'                = '08-platform-style-encoding.md'
    '17'                = '08-platform-style-encoding.md'
    '15'                = '09-output-logging-files.md'
    '20'                = '09-output-logging-files.md'
    'definition-of-done' = '99-definition-of-done.md'
    'lineage'            = '99-definition-of-done.md'
    'deeper-guidance'    = '99-definition-of-done.md'
}

$topicTitles = @{
    '00-non-negotiables.md'        = 'Non-negotiables'
    '01-function-authoring.md'     = 'Function authoring'
    '02-pipeline-errors-safety.md' = 'Output, errors, and safety'
    '03-help-and-prose.md'         = 'Help and prose'
    '04-testing-pester.md'         = 'Testing with Pester v5'
    '05-modules-packaging.md'      = 'Modules, classes, and GUIs'
    '06-performance.md'            = 'Performance'
    '07-security.md'               = 'Security'
    '08-platform-style-encoding.md' = 'Cross-platform, localization, and encoding'
    '09-output-logging-files.md'   = 'Logging and files/reports'
    '99-definition-of-done.md'     = 'Definition of done, lineage, deeper guidance'
}

function Get-StandardSectionKey {
    <#
    .SYNOPSIS
        Maps a top-level upstream heading to its section key, or $null when unknown.
    #>
    param([Parameter(Mandatory)] [string] $Heading)

    if ($Heading -match '^(\d+)\.\s') { return $Matches[1] }
    if ($Heading -eq 'Definition of done') { return 'definition-of-done' }
    if ($Heading -eq 'Lineage') { return 'lineage' }
    if ($Heading -eq 'Deeper guidance') { return 'deeper-guidance' }
    return $null
}

function Split-StandardContent {
    <#
    .SYNOPSIS
        Splits the monolithic upstream markdown into a preamble and ordered sections.
    .DESCRIPTION
        Top-level sections start at fence-aware '## ' lines. Returns the preamble
        (everything before the first '## ') and the ordered section list. The
        preamble's own H1 line is dropped; the topic files get synthetic H1s.
    #>
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Content)

    $preamble = [System.Collections.Generic.List[string]]::new()
    $sections = [System.Collections.Generic.List[object]]::new()
    $inFence = $false
    $current = $null

    foreach ($line in ($Content -split "`r?`n")) {
        if ($line -match '^```') { $inFence = -not $inFence }
        if (-not $inFence -and $line -match '^##\s+(.+?)\s*$') {
            $current = [pscustomobject]@{
                Heading = $Matches[1]
                Lines   = [System.Collections.Generic.List[string]]::new()
            }
            $sections.Add($current)
            $current.Lines.Add($line)
            continue
        }
        if ($null -eq $current) {
            if ($line -notmatch '^#\s+') { $preamble.Add($line) }
        }
        else {
            $current.Lines.Add($line)
        }
    }

    [pscustomobject]@{ Preamble = ($preamble -join "`n"); Sections = $sections }
}

function ConvertTo-VersionStamp {
    <#
    .SYNOPSIS
        Rewrites the '**Upstream version:** x.y.z' line in the index content.
    #>
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Content,
        [Parameter(Mandatory)] [string] $Version
    )
    [regex]::Replace(
        $Content,
        '(\*\*Upstream version:\*\*\s*)v?(\d+(?:\.\d+)+)',
        { param($m) $m.Groups[1].Value + $Version }
    )
}

# ---------------------------------------------------------------------------
# Resolve paths and load the source document.
# ---------------------------------------------------------------------------
if (-not $RepoRoot) {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../../..')).Path
}
elseif (-not (Test-Path -LiteralPath $RepoRoot -PathType Container)) {
    throw "RepoRoot not found: $RepoRoot"
}

$rulesDir = Join-Path $RepoRoot '.agents/rules/powershell'
$indexPath = Join-Path $RepoRoot '.agents/rules/powershell.md'

if ($SourceFile) {
    $content = Get-Content -LiteralPath $SourceFile -Raw
    $resolvedSource = (Resolve-Path -LiteralPath $SourceFile).Path
}
else {
    $response = Invoke-WebRequest -Uri $SourceUrl -TimeoutSec 60
    $content = [string] $response.Content
    $resolvedSource = $SourceUrl
}

if ([string]::IsNullOrWhiteSpace($content)) {
    throw "Upstream document is empty: $resolvedSource"
}

# ---------------------------------------------------------------------------
# Parse versions and decide whether to regenerate.
# ---------------------------------------------------------------------------
$upstreamMatch = [regex]::Match($content, '\*\*Version:\*\*\s*v?(\d+(?:\.\d+)+)')
if (-not $upstreamMatch.Success) {
    throw "Could not parse the upstream version from: $resolvedSource (expected a '**Version:** x.y.z' line)"
}
$upstreamVersion = $upstreamMatch.Groups[1].Value

$indexContent = $null
$currentIndexVersion = $null
if (Test-Path -LiteralPath $indexPath -PathType Leaf) {
    $indexContent = Get-Content -LiteralPath $indexPath -Raw
    $indexMatch = [regex]::Match($indexContent, '\*\*Upstream version:\*\*\s*v?(\d+(?:\.\d+)+)')
    if ($indexMatch.Success) { $currentIndexVersion = $indexMatch.Groups[1].Value }
}
else {
    Write-Warning "Index not found at $indexPath - topic files will be generated but the version will not be stamped."
}

$updateAvailable = ($null -eq $currentIndexVersion) -or ($currentIndexVersion -ne $upstreamVersion)

if (-not $updateAvailable -and -not $Force) {
    Write-Verbose "Upstream v$upstreamVersion matches recorded version - nothing to do."
    return [pscustomobject]@{
        PSTypeName      = 'PSEStandard.RefreshSummary'
        Status          = 'UpToDate'
        UpstreamVersion = $upstreamVersion
        PreviousVersion = $currentIndexVersion
        UpdateAvailable = $false
        CheckOnly       = [bool] $CheckOnly
        FilesWritten    = 0
        FilesUnchanged  = 0
        IndexUpdated    = $false
        RulesDir        = $rulesDir
    }
}

if ($CheckOnly) {
    Write-Verbose "Update available: v$currentIndexVersion -> v$upstreamVersion (check-only, nothing written)."
    return [pscustomobject]@{
        PSTypeName      = 'PSEStandard.RefreshSummary'
        Status          = 'CheckOnly'
        UpstreamVersion = $upstreamVersion
        PreviousVersion = $currentIndexVersion
        UpdateAvailable = $updateAvailable
        CheckOnly       = $true
        FilesWritten    = 0
        FilesUnchanged  = 0
        IndexUpdated    = $false
        RulesDir        = $rulesDir
    }
}

# ---------------------------------------------------------------------------
# Split and validate the section inventory.
# ---------------------------------------------------------------------------
$parsed = Split-StandardContent -Content $content
$sectionsByKey = @{}
foreach ($section in $parsed.Sections) {
    $key = Get-StandardSectionKey -Heading $section.Heading
    if ($null -eq $key -or -not $sectionFileMap.ContainsKey($key)) {
        throw ("Unmapped upstream section '## {0}' in {1}. Update `$sectionFileMap in this script " -f
            $section.Heading, $resolvedSource) + 'and the topic table in .agents/rules/powershell.md, then re-run.'
    }
    $sectionsByKey[$key] = $section
}

foreach ($expectedKey in $sectionFileMap.Keys) {
    if (-not $sectionsByKey.ContainsKey($expectedKey)) {
        throw "Expected upstream section key '$expectedKey' is missing from: $resolvedSource. Either upstream restructured the document (update this script) or the source is truncated."
    }
}

# ---------------------------------------------------------------------------
# Build and write the topic files (write only on change).
# ---------------------------------------------------------------------------
$generatedHeader = (
    "<!-- Generated by update-powershell-standard (skill scripts/update-powershell-standard.ps1) - DO NOT EDIT.`n" +
    "     Source: $resolvedSource (PowerShell Engineer Standard v$upstreamVersion, MIT, Jim Tyler)`n" +
    "     Regenerate: run the update-powershell-standard skill. House content belongs in`n" +
    "     .agents/rules/powershell.md, never in these generated files. -->"
)

# Group ordered sections per target file (upstream order preserved within a file).
$sectionsPerFile = [ordered] @{}
foreach ($section in $parsed.Sections) {
    $target = $sectionFileMap[(Get-StandardSectionKey -Heading $section.Heading)]
    if (-not $sectionsPerFile.Contains($target)) { $sectionsPerFile[$target] = [System.Collections.Generic.List[object]]::new() }
    $sectionsPerFile[$target].Add($section)
}

if (-not (Test-Path -LiteralPath $rulesDir -PathType Container)) {
    $null = New-Item -ItemType Directory -Path $rulesDir -Force
}

$filesWritten = [System.Collections.Generic.List[string]]::new()
$filesUnchanged = [System.Collections.Generic.List[string]]::new()

foreach ($target in $sectionsPerFile.Keys) {
    $title = $topicTitles[$target]
    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add($generatedHeader)
    $parts.Add("# PowerShell Engineer Standard - $title (v$upstreamVersion)")
    if ($target -eq '00-non-negotiables.md' -and -not [string]::IsNullOrWhiteSpace($parsed.Preamble)) {
        $parts.Add($parsed.Preamble.TrimEnd())
    }
    foreach ($section in $sectionsPerFile[$target]) {
        $parts.Add((($section.Lines -join "`n").TrimEnd()))
    }
    $newContent = ($parts -join "`n`n") + "`n"

    $targetPath = Join-Path $rulesDir $target
    $unchanged = (Test-Path -LiteralPath $targetPath -PathType Leaf) -and
        ((Get-Content -LiteralPath $targetPath -Raw) -ceq $newContent)
    if ($unchanged) {
        $filesUnchanged.Add($target)
        Write-Verbose "Unchanged: $target"
        continue
    }
    if ($PSCmdlet.ShouldProcess($targetPath, 'Write generated topic file')) {
        Set-Content -LiteralPath $targetPath -Value $newContent -Encoding utf8NoBOM -NoNewline
        $filesWritten.Add($target)
        Write-Verbose "Wrote: $target"
    }
}

# ---------------------------------------------------------------------------
# Stamp the new version into the hand-maintained index (single marked line).
# ---------------------------------------------------------------------------
$indexUpdated = $false
if ($null -ne $indexContent) {
    $newIndexContent = ConvertTo-VersionStamp -Content $indexContent -Version $upstreamVersion
    if ($newIndexContent -cne $indexContent) {
        if ($PSCmdlet.ShouldProcess($indexPath, 'Stamp upstream version into index')) {
            Set-Content -LiteralPath $indexPath -Value $newIndexContent -Encoding utf8NoBOM -NoNewline
            $indexUpdated = $true
        }
    }
}

return [pscustomobject]@{
    PSTypeName      = 'PSEStandard.RefreshSummary'
    Status          = 'Refreshed'
    UpstreamVersion = $upstreamVersion
    PreviousVersion = $currentIndexVersion
    UpdateAvailable = $updateAvailable
    CheckOnly       = $false
    FilesWritten    = $filesWritten.Count
    FilesUnchanged  = $filesUnchanged.Count
    IndexUpdated    = $indexUpdated
    RulesDir        = $rulesDir
}

#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Ensure the Projects v2 board (and its custom fields) exists for a repo.

.DESCRIPTION
    Idempotently creates the GitHub Project (if missing), links it to the repo,
    and ensures the custom fields used by the gh-issue-tracking system:

        Level    (SINGLE_SELECT: plan, epic, story, task)
        Priority (SINGLE_SELECT: P0, P1, P2, P3)
        Estimate (NUMBER)
        Phase    (SINGLE_SELECT: <supplied via -Phases>) -- only when -Phases is provided

    The built-in Status and Milestone fields are provided by the Project itself.

    VIEWS ARE NOT CREATED. GitHub's CLI/API (as of gh 2.46 / Projects v2) has no
    supported way to create Project views programmatically, so the desired views
    are printed for you to add once in the UI. This is a real platform limitation,
    not an omission.

.PARAMETER Owner
    Project owner (user or org) — e.g. the repository owner.

.PARAMETER Repo
    Repository to link, in 'owner/repo' form.

.PARAMETER Title
    Project title (default: the repository name).

.PARAMETER Phases
    Optional phase names. When supplied, a single-select "Phase" field is created
    with these options. Phases are optional and may be omitted entirely.

.PARAMETER DryRun
    Show planned actions without applying them.

.EXAMPLE
    ./.agents/skills/gh-issue-tracking-init/scripts/ensure-project.ps1 -Owner nam20485 -Repo nam20485/SupportAssistant -DryRun

.EXAMPLE
    ./.agents/skills/gh-issue-tracking-init/scripts/ensure-project.ps1 -Owner myorg -Repo myorg/app -Phases 'Current','Future'

.NOTES
    Requires: GitHub CLI (gh) authenticated with the `project` scope.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Owner,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[^/]+/[^/]+$')]
    [string]$Repo,

    [Parameter()]
    [string]$Title,

    [Parameter()]
    [string[]]$Phases,

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

if (-not $Title) { $Title = (Get-RepoParts -Repo $Repo).Name }

# --- Locate or create the project ------------------------------------------
$existing = $null
try {
    $listed = Invoke-GhJson project list --owner $Owner --format json --limit 200
    $projects = Get-JsonProp $listed 'projects'
    if ($null -eq $projects) { $projects = $listed }
    $existing = @($projects | Where-Object { $_.title -eq $Title }) | Select-Object -First 1
}
catch {
    throw "Could not list existing projects: $($_.Exception.Message)"
}

$projectNumber = $null
if ($existing) {
    $projectNumber = [int]$existing.number
    Write-Skip "Project '$Title' already exists (#$projectNumber)."
}
else {
    if ($DryRun) {
        Write-DryRun "Would create project '$Title' under '$Owner' and link it to $Repo."
    }
    else {
        Write-Step "Creating project '$Title' under '$Owner'..."
        $created = Invoke-GhJson project create --owner $Owner --title $Title --format json
        $projectNumber = [int]$created.number
        Write-Ok "Created project #$projectNumber ($($created.url))"
        try {
            Invoke-Gh project link $projectNumber --owner $Owner --repo $Repo | Out-Null
            Write-Ok "Linked project #$projectNumber to $Repo"
        }
        catch {
            Write-Warning "Failed to link project to ${Repo}: $($_.Exception.Message). Link it manually."
        }
    }
}

# --- Ensure custom fields ---------------------------------------------------
$desiredFields = @(
    @{ Name = 'Level';    Type = 'SINGLE_SELECT'; Options = @('plan', 'epic', 'story', 'task') }
    @{ Name = 'Priority'; Type = 'SINGLE_SELECT'; Options = @('P0', 'P1', 'P2', 'P3') }
    @{ Name = 'Estimate'; Type = 'NUMBER';        Options = @() }
)
if ($Phases -and $Phases.Count -gt 0) {
    $desiredFields += @{ Name = 'Phase'; Type = 'SINGLE_SELECT'; Options = $Phases }
}

if ($null -eq $projectNumber) {
    Write-DryRun "Would ensure fields: $(( $desiredFields | ForEach-Object { $_.Name } ) -join ', ')."
}
else {
    $existingFieldNames = @()
    try {
        $fieldData = Invoke-GhJson project field-list $projectNumber --owner $Owner --format json --limit 200
        $fields = Get-JsonProp $fieldData 'fields'
        if ($null -eq $fields) { $fields = $fieldData }
        $existingFieldNames = @($fields | ForEach-Object { $_.name })
    }
    catch {
        throw "Could not list project fields: $($_.Exception.Message)"
    }

    foreach ($f in $desiredFields) {
        if ($existingFieldNames -contains $f.Name) {
            Write-Skip "Field '$($f.Name)' already exists."
            continue
        }
        if ($DryRun) {
            Write-DryRun "Would create field '$($f.Name)' ($($f.Type))$(if ($f.Options.Count) { " [$($f.Options -join ', ')]" })."
            continue
        }
        Write-Step "Creating field '$($f.Name)' ($($f.Type))..."
        $fieldArgs = @('project', 'field-create', $projectNumber, '--owner', $Owner, '--name', $f.Name, '--data-type', $f.Type)
        if ($f.Type -eq 'SINGLE_SELECT') { $fieldArgs += @('--single-select-options', ($f.Options -join ',')) }
        Invoke-Gh @fieldArgs | Out-Null
        Write-Ok "Created field '$($f.Name)'."
    }

    # The built-in Status field cannot have options edited via gh 2.46; note desired options.
    Write-Skip "Note: ensure the built-in 'Status' field has options: Todo, In Progress, In Review, Blocked, Done (add any missing ones in the UI)."
}

# --- Emit project number on stdout so composing drivers can capture it via $() ---
# (Host-stream Write-* above are human-readable status; this is the machine-readable contract,
#  matching ensure-issue.ps1 which Write-Outputs its issue number.)
if ($null -ne $projectNumber) {
    Write-Output $projectNumber
}

# --- Views (not automatable) ------------------------------------------------
Write-Host ''
Write-Step 'Views to create manually in the Project UI (not creatable via gh/API):'
Write-Host '  - "By Phase"    : group by the Phase field'
Write-Host '  - "By Status"   : board layout grouped by Status'
Write-Host '  - "By Epic"     : group by parent issue / Level = epic'
Write-Host '  - "Current work": filter to open, unblocked items in the active phase/milestone'

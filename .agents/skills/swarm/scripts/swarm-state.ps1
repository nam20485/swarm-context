#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Deterministic on-disk state manager for the agent swarm.

.DESCRIPTION
    Every state mutation for a swarm run goes through this script; state.json is
    never hand-edited. A run lives under <BaseDir>/<runId>/ (default .swarm/,
    gitignored) as goal.md (the goal, one line), field-guide.md (durable
    findings, one bullet per line), and state.json (the schema below).

    state.json schema:
      runId, goal, maxSubagents, spawned, round, status, summary,
      startedAt, endedAt, tasks[] (id/agent/summary/status/round),
      rounds[] (round/startedAt/endedAt/verdict/next)

    Usage:
        swarm-state.ps1 init -Goal "ship feature X" -MaxSubagents 10
        swarm-state.ps1 start-round
        swarm-state.ps1 record-task -TaskId T1 -Agent swarm-implementer -Summary "impl" -Status pending
        swarm-state.ps1 end-round -Verdict not-met -Next "fix build"
        swarm-state.ps1 append-note -Text "found root cause"
        swarm-state.ps1 finish -Status stopped -Summary "stall guard"
        swarm-state.ps1 status

    All operations except init take -RunId (default: lexicographically latest
    run-* directory under -BaseDir). end-round -Verdict met is the success path
    (it sets status/endedAt/summary); finish -Status stopped is the explicit
    stop override for stall guard, user interrupt, or recording the end of a
    budget-exhausted run.

.NOTES
    Serialization is pinned to `$state | ConvertTo-Json -Depth 10` on the state
    object — never on a bare array property — so tasks/rounds stay JSON arrays
    at any element count (PowerShell unwraps single-element arrays in some
    pipeline forms).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('init', 'start-round', 'record-task', 'end-round', 'append-note', 'finish', 'status')]
    [string]$Operation,

    # init
    [string]$Goal,
    [ValidateRange(1, [int]::MaxValue)]
    [int]$MaxSubagents = 50,

    # record-task
    [string]$TaskId,
    [string]$Agent,
    [string]$Summary,
    [int]$Round,

    # record-task (pending|running|done|failed) / finish (stopped) — the two
    # operations use disjoint value sets, so validation is per-operation.
    [string]$Status,

    # end-round
    [ValidateSet('met', 'not-met')]
    [string]$Verdict,
    [string]$Next,

    # append-note
    [string]$Text,

    # common
    [string]$RunId,
    [string]$BaseDir = '.swarm'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-SwarmTimestamp {
    [DateTimeOffset]::UtcNow.ToString('o')
}

function Get-SwarmRunDir {
    param([string]$BaseDir, [string]$RunId)
    if ($RunId) {
        $dir = Join-Path $BaseDir $RunId
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            throw "Run directory not found: $dir"
        }
        return $dir
    }
    # -ErrorAction SilentlyContinue: a missing BaseDir must surface as the
    # domain error below, not a Get-ChildItem path error ($ErrorActionPreference is Stop).
    $latest = @(Get-ChildItem -LiteralPath $BaseDir -Directory -Filter 'run-*' -ErrorAction SilentlyContinue) |
        Sort-Object Name | Select-Object -Last 1
    if (-not $latest) {
        throw "No swarm runs found under '$BaseDir'"
    }
    return $latest.FullName
}

function Get-SwarmState {
    param([string]$RunDir)
    $path = Join-Path $RunDir 'state.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "State file not found: $path"
    }
    Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
}

function Set-SwarmState {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$RunDir
    )
    $State | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $RunDir 'state.json') -Encoding utf8NoBOM
}

switch ($Operation) {

    'init' {
        if ([string]::IsNullOrWhiteSpace($Goal)) {
            throw 'init requires -Goal'
        }
        $runId = 'run-' + [DateTimeOffset]::UtcNow.ToString('yyyyMMdd-HHmmss')
        $runDir = Join-Path $BaseDir $runId
        if (Test-Path -LiteralPath $runDir) {
            throw "Run directory already exists: $runDir"
        }
        New-Item -ItemType Directory -Path $runDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $runDir 'goal.md') -Value $Goal -Encoding utf8NoBOM
        New-Item -ItemType File -Path (Join-Path $runDir 'field-guide.md') -Force | Out-Null
        $state = [pscustomobject]@{
            runId        = $runId
            goal         = $Goal
            maxSubagents = $MaxSubagents
            spawned      = 0
            round        = 0
            status       = 'running'
            summary      = $null
            startedAt    = Get-SwarmTimestamp
            endedAt      = $null
            tasks        = @()
            rounds       = @()
        }
        Set-SwarmState -State $state -RunDir $runDir
        Write-Output $runId
    }

    'start-round' {
        $runDir = Get-SwarmRunDir -BaseDir $BaseDir -RunId $RunId
        $state = Get-SwarmState -RunDir $runDir
        if ($state.status -ne 'running') {
            throw "Run '$($state.runId)' is not running (status: $($state.status))"
        }
        if ($state.spawned -ge $state.maxSubagents) {
            # Budget exhausted: the orchestrator must see this line, not an
            # exception. endedAt stays null so finish can still record the end.
            $state.status = 'stopped'
            Set-SwarmState -State $state -RunDir $runDir
            Write-Output "BUDGET EXHAUSTED: spawned $($state.spawned) of $($state.maxSubagents) subagents; run stopped."
            return
        }
        $state.round += 1
        $entry = [pscustomobject]@{
            round     = $state.round
            startedAt = Get-SwarmTimestamp
            endedAt   = $null
            verdict   = $null
            next      = $null
        }
        $state.rounds = @($state.rounds) + $entry
        Set-SwarmState -State $state -RunDir $runDir
        Write-Output $state.round
    }

    'record-task' {
        if ([string]::IsNullOrWhiteSpace($TaskId)) { throw 'record-task requires -TaskId' }
        if ([string]::IsNullOrWhiteSpace($Agent)) { throw 'record-task requires -Agent' }
        if ($null -eq $Summary) { throw 'record-task requires -Summary' }
        $validStatus = @('pending', 'running', 'done', 'failed')
        if ($validStatus -notcontains $Status) {
            throw "Invalid -Status '$Status' for record-task. Valid values: $($validStatus -join ', ')."
        }
        $runDir = Get-SwarmRunDir -BaseDir $BaseDir -RunId $RunId
        $state = Get-SwarmState -RunDir $runDir
        $existing = @($state.tasks | Where-Object { $_.id -eq $TaskId })
        if ($existing.Count -gt 0) {
            $task = $existing[0]
            $task.agent = $Agent
            $task.summary = $Summary
            $task.status = $Status
            if ($PSBoundParameters.ContainsKey('Round')) { $task.round = $Round }
        }
        else {
            $taskRound = if ($PSBoundParameters.ContainsKey('Round')) { $Round } else { $state.round }
            $task = [pscustomobject]@{
                id      = $TaskId
                agent   = $Agent
                summary = $Summary
                status  = $Status
                round   = $taskRound
            }
            $state.tasks = @($state.tasks) + $task
            $state.spawned += 1
        }
        Set-SwarmState -State $state -RunDir $runDir
        $task | ConvertTo-Json -Depth 5
    }

    'end-round' {
        if (-not $Verdict) { throw 'end-round requires -Verdict (met|not-met)' }
        $runDir = Get-SwarmRunDir -BaseDir $BaseDir -RunId $RunId
        $state = Get-SwarmState -RunDir $runDir
        $open = @($state.rounds | Where-Object { $null -eq $_.endedAt }) | Select-Object -Last 1
        if (-not $open) {
            throw "No open round in run '$($state.runId)'"
        }
        $open.verdict = $Verdict
        $open.next = if ($PSBoundParameters.ContainsKey('Next')) { $Next } else { $null }
        $open.endedAt = Get-SwarmTimestamp
        if ($Verdict -eq 'met') {
            # Success path: sets the run-level end state. finish must NOT be
            # called after this (it would throw on the endedAt guard).
            $state.status = 'achieved'
            $state.endedAt = $open.endedAt
            $state.summary = "Goal met in round $($open.round)"
            Set-SwarmState -State $state -RunDir $runDir
            Write-Output "Goal met in round $($open.round)"
        }
        else {
            Set-SwarmState -State $state -RunDir $runDir
            Write-Output "Round $($open.round) $Verdict. Next: $($open.next)"
        }
    }

    'append-note' {
        if ($null -eq $Text) { throw 'append-note requires -Text' }
        $runDir = Get-SwarmRunDir -BaseDir $BaseDir -RunId $RunId
        # One bullet per line: collapse any embedded newlines.
        $singleLine = $Text -replace '\r?\n|\r', ' '
        Add-Content -LiteralPath (Join-Path $runDir 'field-guide.md') -Value "- $singleLine" -Encoding utf8NoBOM
    }

    'finish' {
        if ($Status -ne 'stopped') {
            throw "Invalid -Status '$Status' for finish. Only 'stopped' is valid."
        }
        if ($null -eq $Summary) { throw 'finish requires -Summary' }
        $runDir = Get-SwarmRunDir -BaseDir $BaseDir -RunId $RunId
        $state = Get-SwarmState -RunDir $runDir
        # Guard on endedAt, not status: a budget-exhausted start-round sets
        # status 'stopped' but leaves endedAt null, and finish must still work.
        if ($null -ne $state.endedAt) {
            throw "Run '$($state.runId)' already finished (status: $($state.status))"
        }
        $state.status = $Status
        $state.endedAt = Get-SwarmTimestamp
        $state.summary = $Summary
        Set-SwarmState -State $state -RunDir $runDir
        Write-Output "Run $($state.runId) $($state.status): $($state.summary)"
    }

    'status' {
        $runDir = Get-SwarmRunDir -BaseDir $BaseDir -RunId $RunId
        $path = Join-Path $runDir 'state.json'
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "State file not found: $path"
        }
        Write-Output (Get-Content -LiteralPath $path -Raw)
    }
}

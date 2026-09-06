#!/usr/bin/env pwsh
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
    Unit tests for swarm-state.ps1 from the swarm skill.

    The script is exercised against a fresh temp -BaseDir per test — never the
    repo's .swarm/ directory. Run ids are second-resolution timestamps
    (run-<yyyyMMdd-HHmmss>), so tests needing two distinct runs sleep past the
    second boundary instead of relying on sub-second timing.

    Run:  Invoke-Pester -Path .agents/skills/swarm/scripts/tests -Output Detailed
#>

Describe 'swarm-state.ps1' {

    BeforeAll {
        # Single BeforeAll per Describe (Pester 5 gotcha: a second block breaks
        # $script:-scoped visibility for the whole Describe).
        $skillScriptsDir = Split-Path -Parent $PSScriptRoot
        $script:StateScript = Join-Path $skillScriptsDir 'swarm-state.ps1'
        $script:Cleanup = @()

        function Get-TestState {
            param([string]$BaseDir, [string]$RunId)
            Get-Content -LiteralPath (Join-Path (Join-Path $BaseDir $RunId) 'state.json') -Raw | ConvertFrom-Json
        }
    }

    BeforeEach {
        $script:BaseDir = Join-Path ([System.IO.Path]::GetTempPath()) ("swarm-tests-" + [guid]::NewGuid().ToString('N'))
        $script:Cleanup += $script:BaseDir
    }

    AfterEach {
        foreach ($dir in $script:Cleanup) {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
        $script:Cleanup = @()
    }

    AfterAll {
        foreach ($dir in $script:Cleanup) {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'init' {

        It 'creates the run dir with goal.md, field-guide.md, and state.json; prints only the run id' {
            $out = & $script:StateScript init -Goal 'test goal' -BaseDir $script:BaseDir
            @($out) | Should -HaveCount 1
            $runId = @($out)[0]
            $runId | Should -Match '^run-\d{8}-\d{6}$'
            $runDir = Join-Path $script:BaseDir $runId
            (Test-Path -LiteralPath (Join-Path $runDir 'goal.md')) | Should -BeTrue
            (Test-Path -LiteralPath (Join-Path $runDir 'field-guide.md')) | Should -BeTrue
            (Get-Item -LiteralPath (Join-Path $runDir 'field-guide.md')).Length | Should -Be 0
            (Get-Content -LiteralPath (Join-Path $runDir 'goal.md') -Raw) | Should -Match '^test goal'

            $state = Get-TestState -BaseDir $script:BaseDir -RunId $runId
            $state.runId | Should -Be $runId
            $state.goal | Should -Be 'test goal'
            $state.maxSubagents | Should -Be 50
            $state.spawned | Should -Be 0
            $state.round | Should -Be 0
            $state.status | Should -Be 'running'
            $state.summary | Should -BeNullOrEmpty
            $state.endedAt | Should -BeNullOrEmpty
            # Assert on the raw file: ConvertFrom-Json auto-parses the ISO stamp
            # into a [DateTimeOffset], so the parsed property is not the file text.
            (Get-Content -LiteralPath (Join-Path $runDir 'state.json') -Raw) |
                Should -Match '"startedAt"\s*:\s*"\d{4}-\d{2}-\d{2}T'
            @($state.tasks).Count | Should -Be 0
            @($state.rounds).Count | Should -Be 0
        }

        It 'honors -MaxSubagents' {
            $runId = & $script:StateScript init -Goal 'g' -MaxSubagents 3 -BaseDir $script:BaseDir
            (Get-TestState -BaseDir $script:BaseDir -RunId $runId).maxSubagents | Should -Be 3
        }

        It 'throws when -Goal is missing' {
            { & $script:StateScript init -BaseDir $script:BaseDir } | Should -Throw 'init requires -Goal'
        }

        It 'throws on run-id collision' {
            # The run id is timestamp-derived; pre-create the directories the
            # next few seconds would generate so the collision is deterministic.
            $now = [DateTimeOffset]::UtcNow
            foreach ($offset in 0..2) {
                $candidate = 'run-' + $now.AddSeconds($offset).ToString('yyyyMMdd-HHmmss')
                New-Item -ItemType Directory -Path (Join-Path $script:BaseDir $candidate) -Force | Out-Null
            }
            { & $script:StateScript init -Goal 'g' -BaseDir $script:BaseDir } | Should -Throw 'Run directory already exists*'
        }
    }

    Context 'start-round' {

        It 'opens round 1 and prints the round number' {
            $runId = & $script:StateScript init -Goal 'g' -BaseDir $script:BaseDir
            $out = & $script:StateScript start-round -BaseDir $script:BaseDir -RunId $runId
            $out | Should -Be 1
            $state = Get-TestState -BaseDir $script:BaseDir -RunId $runId
            $state.round | Should -Be 1
            @($state.rounds).Count | Should -Be 1
            $state.rounds[0].round | Should -Be 1
            $state.rounds[0].endedAt | Should -BeNullOrEmpty
            $state.rounds[0].verdict | Should -BeNullOrEmpty
            $state.status | Should -Be 'running'
        }

        It 'throws when the run is not running' {
            $runId = & $script:StateScript init -Goal 'g' -BaseDir $script:BaseDir
            $null = & $script:StateScript start-round -BaseDir $script:BaseDir -RunId $runId
            $null = & $script:StateScript end-round -Verdict met -BaseDir $script:BaseDir -RunId $runId
            { & $script:StateScript start-round -BaseDir $script:BaseDir -RunId $runId } |
                Should -Throw "Run '*' is not running (status: achieved)"
        }

        It 'stops the run on budget exhaustion with the exact stdout line, leaving endedAt null' {
            $runId = & $script:StateScript init -Goal 'g' -MaxSubagents 1 -BaseDir $script:BaseDir
            $null = & $script:StateScript record-task -TaskId T1 -Agent swarm-implementer -Summary 'x' -Status done -BaseDir $script:BaseDir -RunId $runId
            $out = & $script:StateScript start-round -BaseDir $script:BaseDir -RunId $runId
            $out | Should -Be 'BUDGET EXHAUSTED: spawned 1 of 1 subagents; run stopped.'
            $state = Get-TestState -BaseDir $script:BaseDir -RunId $runId
            $state.status | Should -Be 'stopped'
            $state.endedAt | Should -BeNullOrEmpty
            $state.round | Should -Be 0
        }

        It 'finish succeeds after a budget-exhausted start-round (endedAt guard, not status)' {
            $runId = & $script:StateScript init -Goal 'g' -MaxSubagents 1 -BaseDir $script:BaseDir
            $null = & $script:StateScript record-task -TaskId T1 -Agent swarm-implementer -Summary 'x' -Status done -BaseDir $script:BaseDir -RunId $runId
            $null = & $script:StateScript start-round -BaseDir $script:BaseDir -RunId $runId
            $out = & $script:StateScript finish -Status stopped -Summary 'budget test' -BaseDir $script:BaseDir -RunId $runId
            $out | Should -Be "Run $runId stopped: budget test"
            $state = Get-TestState -BaseDir $script:BaseDir -RunId $runId
            $state.status | Should -Be 'stopped'
            $state.endedAt | Should -Not -BeNullOrEmpty
            $state.summary | Should -Be 'budget test'
        }
    }

    Context 'record-task' {

        It 'increments spawned for a new task id and prints the task JSON' {
            $runId = & $script:StateScript init -Goal 'g' -BaseDir $script:BaseDir
            $null = & $script:StateScript start-round -BaseDir $script:BaseDir -RunId $runId
            $out = & $script:StateScript record-task -TaskId T1 -Agent swarm-implementer -Summary 'impl' -Status pending -BaseDir $script:BaseDir -RunId $runId
            $task = $out | ConvertFrom-Json
            $task.id | Should -Be 'T1'
            $task.agent | Should -Be 'swarm-implementer'
            $task.status | Should -Be 'pending'
            $task.round | Should -Be 1
            (Get-TestState -BaseDir $script:BaseDir -RunId $runId).spawned | Should -Be 1
        }

        It 'updates fields without incrementing spawned for an existing id' {
            $runId = & $script:StateScript init -Goal 'g' -BaseDir $script:BaseDir
            $null = & $script:StateScript start-round -BaseDir $script:BaseDir -RunId $runId
            $null = & $script:StateScript record-task -TaskId T1 -Agent swarm-implementer -Summary 'impl' -Status pending -BaseDir $script:BaseDir -RunId $runId
            $null = & $script:StateScript record-task -TaskId T1 -Agent swarm-implementer -Summary 'impl v2' -Status done -BaseDir $script:BaseDir -RunId $runId
            $state = Get-TestState -BaseDir $script:BaseDir -RunId $runId
            $state.spawned | Should -Be 1
            @($state.tasks).Count | Should -Be 1
            $state.tasks[0].status | Should -Be 'done'
            $state.tasks[0].summary | Should -Be 'impl v2'
        }

        It 'defaults round to the current round and honors an explicit -Round' {
            $runId = & $script:StateScript init -Goal 'g' -BaseDir $script:BaseDir
            $null = & $script:StateScript start-round -BaseDir $script:BaseDir -RunId $runId
            $null = & $script:StateScript record-task -TaskId T1 -Agent a -Summary s -Status pending -Round 7 -BaseDir $script:BaseDir -RunId $runId
            $null = & $script:StateScript record-task -TaskId T2 -Agent a -Summary s -Status pending -BaseDir $script:BaseDir -RunId $runId
            $state = Get-TestState -BaseDir $script:BaseDir -RunId $runId
            $state.tasks | Where-Object { $_.id -eq 'T1' } | Select-Object -ExpandProperty round | Should -Be 7
            $state.tasks | Where-Object { $_.id -eq 'T2' } | Select-Object -ExpandProperty round | Should -Be 1
        }

        It 'rejects an invalid status' {
            $runId = & $script:StateScript init -Goal 'g' -BaseDir $script:BaseDir
            { & $script:StateScript record-task -TaskId T1 -Agent a -Summary s -Status bogus -BaseDir $script:BaseDir -RunId $runId } |
                Should -Throw "Invalid -Status 'bogus' for record-task*"
        }
    }

    Context 'end-round' {

        It 'marks the run achieved on met and stores null next when -Next is omitted' {
            $runId = & $script:StateScript init -Goal 'g' -BaseDir $script:BaseDir
            $null = & $script:StateScript start-round -BaseDir $script:BaseDir -RunId $runId
            $out = & $script:StateScript end-round -Verdict met -BaseDir $script:BaseDir -RunId $runId
            $out | Should -Be 'Goal met in round 1'
            $state = Get-TestState -BaseDir $script:BaseDir -RunId $runId
            $state.status | Should -Be 'achieved'
            $state.endedAt | Should -Not -BeNullOrEmpty
            $state.summary | Should -Be 'Goal met in round 1'
            $state.rounds[0].verdict | Should -Be 'met'
            $state.rounds[0].next | Should -BeNullOrEmpty
            $state.rounds[0].endedAt | Should -Not -BeNullOrEmpty
        }

        It 'records verdict and next on not-met and allows a new round' {
            $runId = & $script:StateScript init -Goal 'g' -BaseDir $script:BaseDir
            $null = & $script:StateScript start-round -BaseDir $script:BaseDir -RunId $runId
            $out = & $script:StateScript end-round -Verdict not-met -Next 'fix build' -BaseDir $script:BaseDir -RunId $runId
            $out | Should -Be 'Round 1 not-met. Next: fix build'
            $state = Get-TestState -BaseDir $script:BaseDir -RunId $runId
            $state.status | Should -Be 'running'
            $state.endedAt | Should -BeNullOrEmpty
            $state.rounds[0].verdict | Should -Be 'not-met'
            $state.rounds[0].next | Should -Be 'fix build'
            (& $script:StateScript start-round -BaseDir $script:BaseDir -RunId $runId) | Should -Be 2
        }

        It 'throws with no open round' {
            $runId = & $script:StateScript init -Goal 'g' -BaseDir $script:BaseDir
            { & $script:StateScript end-round -Verdict met -BaseDir $script:BaseDir -RunId $runId } |
                Should -Throw "No open round in run '*'"
        }
    }

    Context 'append-note' {

        It 'appends one bullet line per note' {
            $runId = & $script:StateScript init -Goal 'g' -BaseDir $script:BaseDir
            $out = & $script:StateScript append-note -Text 'finding one' -BaseDir $script:BaseDir -RunId $runId
            $out | Should -BeNullOrEmpty
            $null = & $script:StateScript append-note -Text 'finding two' -BaseDir $script:BaseDir -RunId $runId
            (Get-Content -LiteralPath (Join-Path (Join-Path $script:BaseDir $runId) 'field-guide.md')) |
                Should -Be @('- finding one', '- finding two')
        }

        It 'collapses embedded newlines to keep one bullet per line' {
            $runId = & $script:StateScript init -Goal 'g' -BaseDir $script:BaseDir
            $null = & $script:StateScript append-note -Text "line one`nline two" -BaseDir $script:BaseDir -RunId $runId
            (Get-Content -LiteralPath (Join-Path (Join-Path $script:BaseDir $runId) 'field-guide.md')) |
                Should -Be @('- line one line two')
        }
    }

    Context 'finish' {

        It 'throws when called twice (endedAt guard)' {
            $runId = & $script:StateScript init -Goal 'g' -BaseDir $script:BaseDir
            $null = & $script:StateScript start-round -BaseDir $script:BaseDir -RunId $runId
            $null = & $script:StateScript end-round -Verdict not-met -Next 'x' -BaseDir $script:BaseDir -RunId $runId
            $null = & $script:StateScript finish -Status stopped -Summary 'first' -BaseDir $script:BaseDir -RunId $runId
            { & $script:StateScript finish -Status stopped -Summary 'second' -BaseDir $script:BaseDir -RunId $runId } |
                Should -Throw "Run '*' already finished*"
        }

        It 'rejects any status other than stopped' {
            $runId = & $script:StateScript init -Goal 'g' -BaseDir $script:BaseDir
            { & $script:StateScript finish -Status achieved -Summary 'x' -BaseDir $script:BaseDir -RunId $runId } |
                Should -Throw "Invalid -Status 'achieved' for finish*"
        }
    }

    Context 'status and run resolution' {

        It 'prints parseable JSON with tasks surviving as an array in a single-task state' {
            $runId = & $script:StateScript init -Goal 'g' -BaseDir $script:BaseDir
            $null = & $script:StateScript start-round -BaseDir $script:BaseDir -RunId $runId
            $null = & $script:StateScript record-task -TaskId T1 -Agent swarm-implementer -Summary 's' -Status pending -BaseDir $script:BaseDir -RunId $runId
            $raw = & $script:StateScript status -BaseDir $script:BaseDir -RunId $runId
            $parsed = $raw | ConvertFrom-Json
            $parsed.status | Should -Be 'running'
            $parsed.tasks -is [array] | Should -BeTrue
            @($parsed.tasks).Count | Should -Be 1
            $parsed.tasks[0].id | Should -Be 'T1'
        }

        It 'throws when no runs exist (base dir missing)' {
            { & $script:StateScript status -BaseDir $script:BaseDir } |
                Should -Throw "No swarm runs found under '*'"
        }

        It 'throws when the base dir exists but has no runs' {
            New-Item -ItemType Directory -Path $script:BaseDir -Force | Out-Null
            { & $script:StateScript status -BaseDir $script:BaseDir } |
                Should -Throw "No swarm runs found under '*'"
        }

        It 'targets an explicit -RunId instead of the latest' {
            $first = & $script:StateScript init -Goal 'g1' -BaseDir $script:BaseDir
            Start-Sleep -Milliseconds 1100   # run ids are second-resolution
            $second = & $script:StateScript init -Goal 'g2' -BaseDir $script:BaseDir
            $first | Should -Not -Be $second
            $null = & $script:StateScript record-task -TaskId T1 -Agent a -Summary s -Status done -BaseDir $script:BaseDir -RunId $first
            (Get-TestState -BaseDir $script:BaseDir -RunId $first).spawned | Should -Be 1
            (Get-TestState -BaseDir $script:BaseDir -RunId $second).spawned | Should -Be 0
        }

        It 'throws on an unknown explicit -RunId' {
            $null = & $script:StateScript init -Goal 'g' -BaseDir $script:BaseDir
            { & $script:StateScript status -RunId 'run-19990101-000000' -BaseDir $script:BaseDir } |
                Should -Throw 'Run directory not found*'
        }

        It 'throws when a run dir has no state.json' {
            $null = & $script:StateScript init -Goal 'g' -BaseDir $script:BaseDir
            $runId = 'run-20000101-000000'
            New-Item -ItemType Directory -Path (Join-Path $script:BaseDir $runId) -Force | Out-Null
            { & $script:StateScript status -RunId $runId -BaseDir $script:BaseDir } |
                Should -Throw 'State file not found*'
        }
    }
}

#!/usr/bin/env pwsh
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
    Pester v5 unit tests for the vendored label-management scripts:

      - import-labels.ps1  (create / update / delete GitHub labels from a JSON export)
      - ensure-labels.ps1  (thin wrapper that delegates to import-labels.ps1)

    Coverage strategy
    -----------------
    Pester's code-coverage breakpoints only trace the runsace that Invoke-Pester
    runs in. Running the scripts inside an isolated [powershell]::Create() child
    runsace yields 0% coverage (the child's debugger is separate). So every
    script invocation runs IN-PROCESS via the call operator (`& $script @Params`)
    in the Pester test runsace, where coverage is measured.

    The scripts call `exit` in several early-return branches. In a bare pwsh
    process `exit` terminates the host, but Pester v5 runs each test in a
    runsace that swallows `exit` (it stops the script and returns the output
    collected so far, without propagating an exception to the It block). This
    lets us exercise the exit branches safely.

    The scripts call the real `gh` CLI directly (import-labels.ps1 does NOT use
    the Invoke-Gh wrapper from common.ps1), so `gh` is stubbed as a
    `function global:gh` (per the repo convention) that records every call
    (joined arg string) into a global List so tests can assert on exactly which
    `gh api` operations were issued. The mock is installed in BeforeEach and
    removed in AfterEach.

    NOTE: common-auth.ps1 (dot-sourced by import-labels.ps1) sets
    $ErrorActionPreference = 'Stop' INSIDE the script's child scope (the call
    operator creates a child scope, so EAP/StrictMode do NOT leak into the test
    runsace). Under Stop, `Write-Error` throws an ActionPreferenceStopException
    that propagates out of `& $script` as a terminating error; the helper catches
    it and folds the message into Errors so error-path tests can match on the
    original Write-Error text.

    Stream capture: `& $script @Params 3>&1 6>&1` merges the Warning (3) and
    Information (6) streams into the success stream. Write-Warning records
    surface as WarningRecord and Write-Host records as InformationRecord, which
    the helper separates by type.

    Run:  Invoke-Pester -Path .agents/skills/gh-issue-tracking-init/scripts/tests/ImportLabels.Tests.ps1 -Output Detailed
#>

Describe 'label management scripts (import-labels / ensure-labels)' {

    BeforeAll {
        # Resolve script paths INSIDE BeforeAll from $PSScriptRoot. In Pester v5,
        # file-top-level variables are set during discovery and are NOT preserved at
        # runtime, so resolving at the file top would yield empty paths at runtime.
        $script:GhitDir = Split-Path -Parent $PSScriptRoot
        $script:SkillDir = Split-Path -Parent $script:GhitDir
        $script:ImportScript = Join-Path $script:GhitDir 'import-labels.ps1'
        $script:EnsureScript = Join-Path $script:GhitDir 'ensure-labels.ps1'
        $script:LabelsJsonPath = Join-Path $script:SkillDir 'assets/labels.json'

        # Run a label script IN-PROCESS (same runsace as Pester, so coverage
        # breakpoints fire) with the global:gh stub installed in BeforeEach.
        # Returns a pscustomobject with: Output, Information, Warnings, Errors,
        # GhCalls, HadError. `exit` inside the script is swallowed by Pester's
        # runsace; terminating errors (Write-Error under EAP=Stop) are caught.
        function Invoke-LabelScript {
            param(
                [Parameter(Mandatory)] [string]$ScriptPath,
                [Parameter(Mandatory)] [hashtable]$Params,
                [string]$ExistingLabelsJson = '[]',
                [switch]$GetLabelsFails
            )

            # Configure the per-call mock parameters consumed by global:gh.
            $global:MockExistingLabels = $ExistingLabelsJson
            $global:MockGetFails = [bool]$GetLabelsFails
            $global:GhCallLog = [System.Collections.Generic.List[object]]::new()
            $global:LASTEXITCODE = 0

            $warnings = [System.Collections.Generic.List[object]]::new()
            $information = [System.Collections.Generic.List[object]]::new()
            $output = [System.Collections.Generic.List[object]]::new()
            $errorMsg = $null

            try {
                # 3>&1 merges Warning, 6>&1 merges Information (Write-Host) into the
                # success stream so all three can be separated by record type below.
                $merged = & $ScriptPath @Params 3>&1 6>&1
                if ($null -ne $merged) {
                    foreach ($m in @($merged)) {
                        if ($m -is [System.Management.Automation.WarningRecord]) {
                            $warnings.Add($m.Message)
                        } elseif ($m -is [System.Management.Automation.InformationRecord]) {
                            $information.Add($m.ToString())
                        } elseif ($null -ne $m) {
                            $output.Add($m)
                        }
                    }
                }
            } catch {
                # Write-Error under EAP=Stop propagates as a terminating error; its
                # message embeds the original Write-Error text after "Stop: ".
                $errorMsg = $_.Exception.Message
            }

            $errors = @()
            if ($errorMsg) { $errors += $errorMsg }

            return [pscustomobject]@{
                Output      = @($output)
                Information = @($information)
                Warnings    = @($warnings)
                Errors      = $errors
                GhCalls     = @($global:GhCallLog)
                HadError    = [bool]$errorMsg
            }
        }

        # Write a raw JSON string to a unique temp file under the per-test temp dir.
        function New-TempLabelsFile {
            param([Parameter(Mandatory)][string]$Json)
            $path = Join-Path $script:TestTempDir ("labels-" + [guid]::NewGuid().ToString('N') + ".json")
            Set-Content -LiteralPath $path -Value $Json -Encoding UTF8
            return $path
        }

        # Convenience accessor: count POST/PATCH/DELETE mutation calls.
        function Get-GhMutationCalls {
            param([Parameter(Mandatory)][string[]]$Calls)
            return @($Calls | Where-Object { $_ -match '-X (POST|PATCH|DELETE)' })
        }
    }

    BeforeEach {
        # Ensure Write-Log is a silent no-op (common.ps1 helpers may call it) so the
        # tests never touch a real logfile. Saved/restored per test.
        $script:SavedLogFile = $env:GHIT_LOG_FILE
        $env:GHIT_LOG_FILE = $null
        $script:TestTempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ghit-imp-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TestTempDir -Force | Out-Null

        # Defaults for the global:gh mock parameters (overridden per call by
        # Invoke-LabelScript). Initialize the call log so the mock always has a
        # valid target even if a test triggers a gh call unexpectedly.
        $global:GhCallLog = [System.Collections.Generic.List[object]]::new()
        $global:MockExistingLabels = '[]'
        $global:MockGetFails = $false
        $global:LASTEXITCODE = 0

        # Stub `gh` as a global function (per repo convention). It records every
        # invocation into $global:GhCallLog and returns canned JSON for each API
        # operation, differentiating by the `-X <METHOD>` token pair. Visible to
        # the scripts via PowerShell dynamic scoping (they call `gh` / `& gh`).
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
            $all = if ($null -eq $Arguments) { @() } else { @($Arguments | ForEach-Object { [string]$_ }) }
            $null = $global:GhCallLog.Add(($all -join ' '))
            $global:LASTEXITCODE = 0
            if ($all.Count -eq 0) { return }
            # auth status probe (from Initialize-GitHubAuth) -> succeed silently
            if ($all -ccontains 'auth' -and $all -ccontains 'status') { return }
            # detect the HTTP method from a `-X <METHOD>` token pair
            $method = ''
            for ($i = 0; $i -lt ($all.Count - 1); $i++) {
                if ($all[$i] -ceq '-X') { $method = [string]$all[$i + 1]; break }
            }
            if ($method -ceq 'DELETE') { return }
            if ($method -ceq 'POST')   { return '{"name":"x","color":"000000","description":""}' }
            if ($method -ceq 'PATCH')  { return '{"name":"x","color":"000000","description":""}' }
            # anything else is the GET labels list
            if ($global:MockGetFails) { $global:LASTEXITCODE = 1; throw 'gh api failed (mocked)' }
            return $global:MockExistingLabels
        }
    }

    AfterEach {
        Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
        $env:GHIT_LOG_FILE = $script:SavedLogFile
        if ($script:TestTempDir -and (Test-Path -LiteralPath $script:TestTempDir)) {
            Remove-Item -LiteralPath $script:TestTempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }


    Describe 'import-labels.ps1' {

        Context 'parameter validation' {
            # ValidatePattern throws a terminating ParameterBindingException during
            # binding, before the script body (and before any `exit`), so this is
            # safe to run directly.
            It 'rejects a malformed -Repo' {
                { & $script:ImportScript -Repo 'no-slash' -LabelsFile 'does-not-exist.json' } | Should -Throw
            }
        }

        Context 'labels file loading and early exits' {
            It 'errors and halts when the labels file is not found' {
                $r = Invoke-LabelScript -ScriptPath $script:ImportScript -Params @{
                    Repo = 'o/r'
                    LabelsFile = (Join-Path $script:TestTempDir 'nope.json')
                }
                $r.Errors | Should -Not -BeNullOrEmpty
                ($r.Errors | Where-Object { $_ -match 'Labels file not found' }).Count | Should -BeGreaterThan 0
                # auth runs before the file check; the labels GET never runs.
                @($r.GhCalls | Where-Object { $_ -match 'auth' }).Count | Should -Be 1
                @($r.GhCalls | Where-Object { $_ -match '--paginate' }).Count | Should -Be 0
                (Get-GhMutationCalls $r.GhCalls).Count | Should -Be 0
            }

            It 'errors and halts when the labels file contains invalid JSON' {
                $bad = New-TempLabelsFile -Json '{not valid json'
                $r = Invoke-LabelScript -ScriptPath $script:ImportScript -Params @{
                    Repo = 'o/r'
                    LabelsFile = $bad
                }
                $r.Errors | Should -Not -BeNullOrEmpty
                ($r.Errors | Where-Object { $_ -match 'Failed to parse JSON' }).Count | Should -BeGreaterThan 0
                @($r.GhCalls | Where-Object { $_ -match '--paginate' }).Count | Should -Be 0
                (Get-GhMutationCalls $r.GhCalls).Count | Should -Be 0
            }

            It 'warns and halts cleanly when the labels file is an empty array ([])' {
                $empty = New-TempLabelsFile -Json '[]'
                $r = Invoke-LabelScript -ScriptPath $script:ImportScript -Params @{
                    Repo = 'o/r'
                    LabelsFile = $empty
                }
                $r.Errors | Should -BeNullOrEmpty
                ($r.Warnings | Where-Object { $_ -match 'No labels found' }).Count | Should -Be 1
                # Empty labels exits before the labels GET, so only the auth probe ran.
                @($r.GhCalls | Where-Object { $_ -match '--paginate' }).Count | Should -Be 0
                (Get-GhMutationCalls $r.GhCalls).Count | Should -Be 0
            }

            It 'warns and halts cleanly when the labels file is JSON null' {
                $nullFile = New-TempLabelsFile -Json 'null'
                $r = Invoke-LabelScript -ScriptPath $script:ImportScript -Params @{
                    Repo = 'o/r'
                    LabelsFile = $nullFile
                }
                $r.Errors | Should -BeNullOrEmpty
                ($r.Warnings | Where-Object { $_ -match 'No labels found' }).Count | Should -Be 1
                (Get-GhMutationCalls $r.GhCalls).Count | Should -Be 0
            }
        }

        Context 'label comparison and action planning (dry-run)' {
            It 'reports no changes when source labels match existing labels' {
                $src = New-TempLabelsFile -Json '[{"name":"A","color":"ff0000","description":"d"}]'
                $r = Invoke-LabelScript -ScriptPath $script:ImportScript -Params @{
                    Repo = 'o/r'; LabelsFile = $src; DryRun = $true
                } -ExistingLabelsJson '[{"name":"A","color":"ff0000","description":"d"}]'
                $r.Errors | Should -BeNullOrEmpty
                ($r.Information | Where-Object { $_ -match 'No changes required' }).Count | Should -Be 1
                @($r.GhCalls | Where-Object { $_ -match '--paginate' }).Count | Should -Be 1
                (Get-GhMutationCalls $r.GhCalls).Count | Should -Be 0
            }

            It 'plans a create action for a missing label (dry-run makes no mutations)' {
                $src = New-TempLabelsFile -Json '[{"name":"NewLabel","color":"ff0000","description":"d"}]'
                $r = Invoke-LabelScript -ScriptPath $script:ImportScript -Params @{
                    Repo = 'o/r'; LabelsFile = $src; DryRun = $true
                } -ExistingLabelsJson '[]'
                $r.Errors | Should -BeNullOrEmpty
                ($r.Information | Where-Object { $_ -match 'create: NewLabel' }).Count | Should -Be 1
                ($r.Information | Where-Object { $_ -match 'Dry run' }).Count | Should -Be 1
                (Get-GhMutationCalls $r.GhCalls).Count | Should -Be 0
            }

            It 'plans an update action when the color differs (dry-run)' {
                $src = New-TempLabelsFile -Json '[{"name":"A","color":"ff0000","description":"d"}]'
                $r = Invoke-LabelScript -ScriptPath $script:ImportScript -Params @{
                    Repo = 'o/r'; LabelsFile = $src; DryRun = $true
                } -ExistingLabelsJson '[{"name":"A","color":"000000","description":"d"}]'
                ($r.Information | Where-Object { $_ -match 'update: A' }).Count | Should -Be 1
                (Get-GhMutationCalls $r.GhCalls).Count | Should -Be 0
            }

            It 'plans an update action when the description differs (dry-run)' {
                $src = New-TempLabelsFile -Json '[{"name":"A","color":"ff0000","description":"newdesc"}]'
                $r = Invoke-LabelScript -ScriptPath $script:ImportScript -Params @{
                    Repo = 'o/r'; LabelsFile = $src; DryRun = $true
                } -ExistingLabelsJson '[{"name":"A","color":"ff0000","description":"olddesc"}]'
                ($r.Information | Where-Object { $_ -match 'update: A' }).Count | Should -Be 1
                (Get-GhMutationCalls $r.GhCalls).Count | Should -Be 0
            }

            It 'plans a delete action with -DeleteMissing (dry-run)' {
                $src = New-TempLabelsFile -Json '[{"name":"A","color":"ff0000","description":"d"}]'
                $r = Invoke-LabelScript -ScriptPath $script:ImportScript -Params @{
                    Repo = 'o/r'; LabelsFile = $src; DryRun = $true; DeleteMissing = $true
                } -ExistingLabelsJson '[{"name":"A","color":"ff0000","description":"d"},{"name":"Orphan","color":"123456","description":"x"}]'
                ($r.Information | Where-Object { $_ -match 'delete: Orphan' }).Count | Should -Be 1
                # A matches -> no create/update; only the delete is planned.
                ($r.Information | Where-Object { $_ -match 'create:|update:' }).Count | Should -Be 0
                (Get-GhMutationCalls $r.GhCalls).Count | Should -Be 0
            }

            It 'normalizes a color with a leading hash and uppercase so no spurious update is planned' {
                $src = New-TempLabelsFile -Json '[{"name":"A","color":"#FFAA00","description":"d"}]'
                $r = Invoke-LabelScript -ScriptPath $script:ImportScript -Params @{
                    Repo = 'o/r'; LabelsFile = $src
                } -ExistingLabelsJson '[{"name":"A","color":"ffaa00","description":"d"}]'
                $r.Errors | Should -BeNullOrEmpty
                ($r.Information | Where-Object { $_ -match 'No changes required' }).Count | Should -Be 1
                (Get-GhMutationCalls $r.GhCalls).Count | Should -Be 0
            }

            It 'treats a null source description as equal to an empty existing description (no update)' {
                # Use an explicit "description":null so the property EXISTS on the
                # PSCustomObject (omitting it would throw under Set-StrictMode).
                $src = New-TempLabelsFile -Json '[{"name":"A","color":"ff0000","description":null}]'
                $r = Invoke-LabelScript -ScriptPath $script:ImportScript -Params @{
                    Repo = 'o/r'; LabelsFile = $src
                } -ExistingLabelsJson '[{"name":"A","color":"ff0000","description":""}]'
                ($r.Information | Where-Object { $_ -match 'No changes required' }).Count | Should -Be 1
                (Get-GhMutationCalls $r.GhCalls).Count | Should -Be 0
            }

            It 'treats an empty source description as equal to a null existing description (no update)' {
                $src = New-TempLabelsFile -Json '[{"name":"A","color":"ff0000","description":""}]'
                $r = Invoke-LabelScript -ScriptPath $script:ImportScript -Params @{
                    Repo = 'o/r'; LabelsFile = $src
                } -ExistingLabelsJson '[{"name":"A","color":"ff0000","description":null}]'
                ($r.Information | Where-Object { $_ -match 'No changes required' }).Count | Should -Be 1
                (Get-GhMutationCalls $r.GhCalls).Count | Should -Be 0
            }

            It 'skips source labels that have no name' {
                # "name":null makes the property exist (StrictMode-safe) but
                # [string]$null -> '' which the `if (-not $name) { continue }`
                # guard skips.
                $src = New-TempLabelsFile -Json '[{"name":null,"color":"ff0000"},{"name":"A","color":"ff0000","description":"d"}]'
                $r = Invoke-LabelScript -ScriptPath $script:ImportScript -Params @{
                    Repo = 'o/r'; LabelsFile = $src
                } -ExistingLabelsJson '[]'
                $posts = @($r.GhCalls | Where-Object { $_ -match '-X POST' })
                $posts.Count | Should -Be 1
                $posts[0] | Should -Match 'name=A'
            }
        }

        Context 'label execution (mocked gh, non-dry-run)' {
            It 'creates a missing label via gh POST' {
                $src = New-TempLabelsFile -Json '[{"name":"A","color":"ff0000","description":"d"}]'
                $r = Invoke-LabelScript -ScriptPath $script:ImportScript -Params @{
                    Repo = 'o/r'; LabelsFile = $src
                } -ExistingLabelsJson '[]'
                $r.Errors | Should -BeNullOrEmpty
                $posts = @($r.GhCalls | Where-Object { $_ -match '-X POST' })
                $posts.Count | Should -Be 1
                $posts[0] | Should -Match 'repos/o/r/labels'
                $posts[0] | Should -Match 'name=A'
                $posts[0] | Should -Match 'color=ff0000'
                $posts[0] | Should -Match 'description=d'
            }

            It 'sends a normalized color (no leading hash, lowercase) on create' {
                $src = New-TempLabelsFile -Json '[{"name":"A","color":"#FFAA00","description":"d"}]'
                $r = Invoke-LabelScript -ScriptPath $script:ImportScript -Params @{
                    Repo = 'o/r'; LabelsFile = $src
                } -ExistingLabelsJson '[]'
                $posts = @($r.GhCalls | Where-Object { $_ -match '-X POST' })
                $posts.Count | Should -Be 1
                $posts[0] | Should -Match 'color=ffaa00'
                $posts[0] | Should -Not -Match '#'
            }

            It 'does not send a color flag when the source label has no color' {
                # "color":null -> property exists (StrictMode-safe); ConvertTo-
                # NormalizedColor returns $null, so no color flag is emitted.
                $src = New-TempLabelsFile -Json '[{"name":"A","color":null,"description":"d"}]'
                $r = Invoke-LabelScript -ScriptPath $script:ImportScript -Params @{
                    Repo = 'o/r'; LabelsFile = $src
                } -ExistingLabelsJson '[]'
                $posts = @($r.GhCalls | Where-Object { $_ -match '-X POST' })
                $posts.Count | Should -Be 1
                $posts[0] | Should -Not -Match 'color='
                $posts[0] | Should -Match 'name=A'
                $posts[0] | Should -Match 'description=d'
            }

            It 'updates an existing label via gh PATCH when the color differs' {
                $src = New-TempLabelsFile -Json '[{"name":"A","color":"ff0000","description":"d"}]'
                $r = Invoke-LabelScript -ScriptPath $script:ImportScript -Params @{
                    Repo = 'o/r'; LabelsFile = $src
                } -ExistingLabelsJson '[{"name":"A","color":"000000","description":"d"}]'
                $r.Errors | Should -BeNullOrEmpty
                $patches = @($r.GhCalls | Where-Object { $_ -match '-X PATCH' })
                $patches.Count | Should -Be 1
                $patches[0] | Should -Match 'new_name=A'
                $patches[0] | Should -Match 'color=ff0000'
                @($r.GhCalls | Where-Object { $_ -match '-X POST' }).Count | Should -Be 0
            }

            It 'updates an existing label via gh PATCH when the description differs' {
                $src = New-TempLabelsFile -Json '[{"name":"A","color":"ff0000","description":"newd"}]'
                $r = Invoke-LabelScript -ScriptPath $script:ImportScript -Params @{
                    Repo = 'o/r'; LabelsFile = $src
                } -ExistingLabelsJson '[{"name":"A","color":"ff0000","description":"oldd"}]'
                $patches = @($r.GhCalls | Where-Object { $_ -match '-X PATCH' })
                $patches.Count | Should -Be 1
                $patches[0] | Should -Match 'new_name=A'
                $patches[0] | Should -Match 'description=newd'
            }

            It 'deletes an orphaned label via gh DELETE with -DeleteMissing' {
                $src = New-TempLabelsFile -Json '[{"name":"A","color":"ff0000","description":"d"}]'
                $r = Invoke-LabelScript -ScriptPath $script:ImportScript -Params @{
                    Repo = 'o/r'; LabelsFile = $src; DeleteMissing = $true
                } -ExistingLabelsJson '[{"name":"A","color":"ff0000","description":"d"},{"name":"Orphan","color":"123456","description":"x"}]'
                $r.Errors | Should -BeNullOrEmpty
                $deletes = @($r.GhCalls | Where-Object { $_ -match '-X DELETE' })
                $deletes.Count | Should -Be 1
                $deletes[0] | Should -Match 'repos/o/r/labels/Orphan'
                # A matches -> no create/update.
                @($r.GhCalls | Where-Object { $_ -match '-X (POST|PATCH)' }).Count | Should -Be 0
            }
        }

        Context 'error handling' {
            It 'errors and halts when fetching existing labels fails' {
                $src = New-TempLabelsFile -Json '[{"name":"A","color":"ff0000","description":"d"}]'
                $r = Invoke-LabelScript -ScriptPath $script:ImportScript -Params @{
                    Repo = 'o/r'; LabelsFile = $src
                } -GetLabelsFails
                $r.Errors | Should -Not -BeNullOrEmpty
                ($r.Errors | Where-Object { $_ -match 'Failed to fetch labels' }).Count | Should -BeGreaterThan 0
                (Get-GhMutationCalls $r.GhCalls).Count | Should -Be 0
            }
        }
    }


    Describe 'ensure-labels.ps1' {

        Context 'parameter validation' {
            It 'rejects a malformed -Repo' {
                { & $script:EnsureScript -Repo 'no-slash' -LabelsFile 'does-not-exist.json' } | Should -Throw
            }
        }

        Context 'labels file and helper guards' {
            It 'throws when the labels file is not found' {
                $r = Invoke-LabelScript -ScriptPath $script:EnsureScript -Params @{
                    Repo = 'o/r'
                    LabelsFile = (Join-Path $script:TestTempDir 'nope.json')
                }
                $r.Errors | Should -Not -BeNullOrEmpty
                ($r.Errors | Where-Object { $_ -match 'Labels file not found' }).Count | Should -BeGreaterThan 0
                # ensure-labels throws before delegating to import-labels, so gh is never called.
                $r.GhCalls.Count | Should -Be 0
            }
        }

        Context 'delegation to import-labels.ps1' {
            It 'uses the default labels file (assets/labels.json) when -LabelsFile is omitted' {
                # Omitting -LabelsFile exercises the parameter default expression
                # (Join-Path (Split-Path -Parent $PSScriptRoot) 'assets/labels.json').
                $r = Invoke-LabelScript -ScriptPath $script:EnsureScript -Params @{
                    Repo = 'o/r'; DryRun = $true
                } -ExistingLabelsJson '[]'
                $r.Errors | Should -BeNullOrEmpty
                ($r.Information | Where-Object { $_ -match 'Ensuring canonical labels' }).Count | Should -Be 1
                @($r.GhCalls | Where-Object { $_ -match '--paginate' }).Count | Should -Be 1
                ($r.Information | Where-Object { $_ -match 'create:' }).Count | Should -BeGreaterThan 0
                (Get-GhMutationCalls $r.GhCalls).Count | Should -Be 0
            }

            It 'delegates in dry-run mode (plans changes, makes no mutations)' {
                $r = Invoke-LabelScript -ScriptPath $script:EnsureScript -Params @{
                    Repo = 'o/r'; LabelsFile = $script:LabelsJsonPath; DryRun = $true
                } -ExistingLabelsJson '[]'
                $r.Errors | Should -BeNullOrEmpty
                # Write-Step header from ensure-labels itself.
                ($r.Information | Where-Object { $_ -match 'Ensuring canonical labels' }).Count | Should -Be 1
                # Delegated import-labels ran the GET and planned creates (dry-run).
                @($r.GhCalls | Where-Object { $_ -match 'auth' }).Count | Should -Be 1
                @($r.GhCalls | Where-Object { $_ -match '--paginate' }).Count | Should -Be 1
                ($r.Information | Where-Object { $_ -match 'create:' }).Count | Should -BeGreaterThan 0
                ($r.Information | Where-Object { $_ -match 'Dry run' }).Count | Should -Be 1
                (Get-GhMutationCalls $r.GhCalls).Count | Should -Be 0
            }

            It 'delegates and creates the canonical labels (non-dry-run)' {
                $r = Invoke-LabelScript -ScriptPath $script:EnsureScript -Params @{
                    Repo = 'o/r'; LabelsFile = $script:LabelsJsonPath
                } -ExistingLabelsJson '[]'
                $r.Errors | Should -BeNullOrEmpty
                $posts = @($r.GhCalls | Where-Object { $_ -match '-X POST' })
                # The canonical assets/labels.json defines 19 labels; with an empty
                # target repo every label is a create.
                $posts.Count | Should -Be 19
                @($r.GhCalls | Where-Object { $_ -match '-X PATCH' }).Count | Should -Be 0
                @($r.GhCalls | Where-Object { $_ -match '-X DELETE' }).Count | Should -Be 0
            }
        }
    }
}

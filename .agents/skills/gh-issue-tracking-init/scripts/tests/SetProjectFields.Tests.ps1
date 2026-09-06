#!/usr/bin/env pwsh
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
    Tests for the $PSBoundParameters.ContainsKey(...) fix in
    set-project-fields.ps1 (the spurious "Field 'Phase' not found" warning).

    When a caller invokes set-project-fields.ps1 without -Phase, the script
    should not add a Phase entry to its single-select collection and should
    emit NO warning — prior to this fix, unbound [string] parameters defaulted
    to "" and the $null -ne guard erroneously passed.

    The warning-path tests run with -DryRun:$false against a stubbed `gh` CLI.
    Asserting warnings under -DryRun would be a false positive: at -DryRun the
    script returns early (before Set-SingleSelect), so no "Field not found"
    warning can ever fire. The script re-dot-sources common.ps1 in its own
    scope, which shadows Pester mocks on the wrapper functions, so we stub
    `gh` directly (the script never defines its own `gh`); a caller-scope
    `function gh` intercepts the underlying `& gh` calls via dynamic scoping —
    the same technique documented in GhIssueTracking.Tests.ps1. This lets the
    real Invoke-Gh/Invoke-GhJson wrappers run and actually reach the
    Set-SingleSelect warning code.

    Run:  Invoke-Pester -Path .agents/skills/gh-issue-tracking-init/scripts/tests/SetProjectFields.Tests.ps1
#>

Describe 'set-project-fields.ps1 single-select parameter guards' {

    # Shared baseline arguments + the helper that invokes
    # set-project-fields.ps1 under -DryRun and captures the merged
    # stdout+warning stream.
    #
    # NOTE: the script path is computed INSIDE BeforeAll from $PSScriptRoot.
    # In Pester v5, file-top-level variables are set during discovery and are
    # NOT preserved at runtime, so resolving the path at the file top yielded
    # an empty $script:ScriptFile at runtime (the real script was never
    # invoked — the old AddScript path silently routed the resulting "& ''"
    # error into the error stream, where Invoke() does not throw, so every
    # test passed vacuously). $PSScriptRoot is an automatic variable that is
    # valid at runtime, so the path resolves correctly here.
    BeforeAll {
        $ghitDir = Split-Path -Parent $PSScriptRoot
        $script:ScriptFile = Join-Path $ghitDir 'set-project-fields.ps1'

        $script:BaseParams = @{
            Owner         = 'test-owner'
            ProjectNumber = 3
            Repo          = 'test-owner/test-repo'
            IssueNumber   = 42
        }

        # Invoke set-project-fields.ps1 in an isolated PowerShell instance
        # using the native AddCommand / AddParameter API rather than a
        # hand-built command string. This avoids all manual quoting/escaping
        # of argument values that may contain spaces, quotes, or special
        # characters. WarningRecord objects surface in $ps.Streams.Warning;
        # the script's Write-Output objects come back from Invoke().
        function Invoke-SetProjectFieldsDryRun {
            param([hashtable]$Params)

            $ps = [powershell]::Create()
            $null = $ps.AddCommand($script:ScriptFile)
            foreach ($k in $Params.Keys) {
                $v = $Params[$k]
                if ($v -is [switch]) {
                    if ($v) { $null = $ps.AddParameter($k) }
                }
                else {
                    $null = $ps.AddParameter($k, $v)
                }
            }

            $raw = @($ps.Invoke())

            $merged = [System.Collections.Generic.List[object]]::new()
            foreach ($w    in @($ps.Streams.Warning)) { $merged.Add($w) }
            foreach ($line in $raw)                   { $merged.Add($line) }
            $ps.Dispose()

            return , $merged
        }
    }

    Context 'DryRun path completes without throwing' {

        It 'completes successfully when no single-select fields are supplied' {
            $p = $script:BaseParams.Clone()
            $p['DryRun'] = [switch]$true
            { Invoke-SetProjectFieldsDryRun -Params $p } | Should -Not -Throw
        }

        It 'completes successfully when an empty-string Phase is passed explicitly' {
            # The $PSBoundParameters.ContainsKey(...) guard only filters
            # unbound params. Explicitly passing -Phase '' still passes the
            # guard by design — the bug was the implicit default when omitted.
            $p = $script:BaseParams.Clone()
            $p['Phase']  = ''
            $p['DryRun'] = [switch]$true
            { Invoke-SetProjectFieldsDryRun -Params $p } | Should -Not -Throw
        }
    }

    Context 'warning paths exercised under -DryRun:$false (mocked gh)' {
        # The stubbed project (field-list) defines NO single-select fields, so
        # any supplied Level/Priority/Phase/Status value triggers
        # Set-SingleSelect's "Field 'X' not found" warning — exercising the
        # exact code path that the ContainsKey guard protects.
        BeforeEach {
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                $global:LASTEXITCODE = 0
                if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return }
                $cmd = $Arguments[0]
                $sub = if ($Arguments.Count -gt 1) { $Arguments[1] } else { '' }
                if ($cmd -eq 'auth'    -and $sub -eq 'status')     { return }
                if ($cmd -eq 'project' -and $sub -eq 'view')       { return '{"id":"PVT_test"}' }
                if ($cmd -eq 'project' -and $sub -eq 'field-list') { return '{"fields":[]}' }
                if ($cmd -eq 'project' -and $sub -eq 'item-add')   { return '{"id":"PVTI_test"}' }
                if ($cmd -eq 'project' -and $sub -eq 'item-edit')  { return }
                return
            }
            $global:LASTEXITCODE = 0
        }

        AfterEach {
            Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
        }

        It 'emits no Field-not-found warning when no single-select fields are supplied' {
            # Reproduces the Phase/Priority/Status/Level bug: before the
            # $PSBoundParameters.ContainsKey fix, unbound [string] params
            # defaulted to "" and $singleSelect held all four keys, producing
            # four "Field not found" warnings. With the fix, $singleSelect is
            # empty, Set-SingleSelect is never called, and zero warnings fire.
            $p = $script:BaseParams.Clone()
            $all = & $script:ScriptFile @p 3>&1

            $warnings = @($all | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
            $warnings | Should -HaveCount 0 -Because "no single-select fields supplied; the ContainsKey guard keeps `$singleSelect empty so Set-SingleSelect is never called."
        }

        It 'emits a Field-not-found warning only for the supplied field (positive control)' {
            # Positive control proving the warning path IS reachable under
            # -DryRun:$false: passing -Level forces Set-SingleSelect('Level'),
            # which warns because the stubbed project defines no 'Level' field.
            # This is what makes the zero-warning assertion above meaningful
            # (it proves zero is due to the guard, not because warnings are
            # impossible to reach). It also confirms only the bound param
            # (Level) is attempted — unbound Phase/Priority/Status never warn.
            $p = $script:BaseParams.Clone()
            $p['Level'] = 'story'
            $all = & $script:ScriptFile @p 3>&1

            $warnings = @($all | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
            $warnings.Count | Should -Be 1
            $warnings[0].Message | Should -Match "Field 'Level' not found"
            $warnings[0].Message | Should -Not -Match 'Phase|Priority|Status'
        }
    }
}

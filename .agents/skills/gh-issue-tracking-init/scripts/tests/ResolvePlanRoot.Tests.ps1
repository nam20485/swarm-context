#!/usr/bin/env pwsh
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
    Pester v5 unit tests for resolve-plan-root.ps1.

    Covers the plan-anchor resolution contract: newest-open-plan targeting in
    continue-existing mode, CreatePlan=true when nothing to continue,
    new-feature-plan always creating, repo-wide next-epic numbering (open +
    closed, non-epic titles ignored, pagination), the -Mode default, the
    zero-gh-call DryRun contract, and parameter validation.

    Conventions (see EnsureIssueAndProject.Tests.ps1):
    - Script paths resolved INSIDE BeforeAll via $PSScriptRoot.
    - gh CLI mocked as `function global:gh` with ValueFromRemainingArguments;
      removed in AfterEach.
    - $global:LASTEXITCODE reset in BeforeEach; gh calls tracked in
      $global:GhCallLog; REST fixtures served from $global:*Page1/$global:*Page2
      keyed by query shape ('labels=plan' vs 'state=all') and page number.
    - No here-string fences; JSON fixtures are plain single-quoted strings.

    Run:  Invoke-Pester -Path .agents/skills/gh-issue-tracking-init/scripts/tests/ResolvePlanRoot.Tests.ps1 -Output Detailed
#>

Describe 'resolve-plan-root.ps1' {
    BeforeAll {
        $ghitDir = Split-Path -Parent $PSScriptRoot
        $script:ResolveScript = Join-Path $ghitDir 'resolve-plan-root.ps1'
    }

    Context 'parameter validation' {
        It 'rejects a malformed -Repo' {
            { & $script:ResolveScript -Repo 'no-slash' } | Should -Throw
        }

        It 'rejects a -Mode outside the ValidateSet' {
            { & $script:ResolveScript -Repo 'o/r' -Mode 'bogus' } | Should -Throw
        }
    }

    Context 'DryRun' {
        BeforeEach {
            $global:GhCallLog = [System.Collections.Generic.List[string]]::new()
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                $global:LASTEXITCODE = 0
                if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return }
                $cmd = $Arguments[0]
                if ($cmd -eq 'auth' -and $Arguments[1] -eq 'status') { return }
                if ($cmd -eq 'api') { $global:GhCallLog.Add(($Arguments -join ' ')) }
            }
            $global:LASTEXITCODE = 0
        }
        AfterEach {
            Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
            Remove-Variable -Name GhCallLog -Scope Global -ErrorAction SilentlyContinue
        }

        It 'makes no gh calls and emits nothing to stdout in DryRun' {
            $out = & $script:ResolveScript -Repo 'o/r' -DryRun
            $out | Should -BeNullOrEmpty
            $global:GhCallLog.Count | Should -Be 0
        }
    }

    Context 'plan anchor resolution (continue-existing)' {
        BeforeEach {
            $global:GhCallLog = [System.Collections.Generic.List[string]]::new()
            $global:OpenPlanPage1 = '[]'
            $global:OpenPlanPage2 = '[]'
            $global:AllIssuesPage1 = '[]'
            $global:AllIssuesPage2 = '[]'
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                $global:LASTEXITCODE = 0
                if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return }
                $cmd = $Arguments[0]
                if ($cmd -eq 'auth' -and $Arguments[1] -eq 'status') { return }
                if ($cmd -eq 'api') {
                    $global:GhCallLog.Add(($Arguments -join ' '))
                    $query = [string]$Arguments[1]
                    $page = 1
                    if ($query -match 'page=(\d+)$') { $page = [int]$Matches[1] }
                    if ($query -like '*labels=plan*') {
                        if ($page -eq 1) { return $global:OpenPlanPage1 } else { return $global:OpenPlanPage2 }
                    }
                    if ($query -like '*state=all*') {
                        if ($page -eq 1) { return $global:AllIssuesPage1 } else { return $global:AllIssuesPage2 }
                    }
                }
            }
            $global:LASTEXITCODE = 0
        }
        AfterEach {
            Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
            Remove-Variable -Name GhCallLog, OpenPlanPage1, OpenPlanPage2, AllIssuesPage1, AllIssuesPage2 -Scope Global -ErrorAction SilentlyContinue
        }

        It 'targets the newest open plan by creation when several exist' {
            $global:OpenPlanPage1 = '[{"number":11,"title":"Plan: First App","created_at":"2026-01-05T10:00:00Z"},{"number":42,"title":"Plan: Second App","created_at":"2026-06-01T10:00:00Z"}]'
            $global:AllIssuesPage1 = '[{"number":20,"title":"Epic 7: Old Thing","created_at":"2026-02-01T10:00:00Z"}]'
            $out = & $script:ResolveScript -Repo 'o/r'
            @($out).Count | Should -Be 1
            $anchor = ([string]($out | Select-Object -First 1)) | ConvertFrom-Json
            $anchor.Mode | Should -Be 'continue-existing'
            $anchor.PlanNumber | Should -Be 42
            $anchor.PlanTitle | Should -Be 'Plan: Second App'
            $anchor.CreatePlan | Should -BeFalse
            $anchor.NextEpicNumber | Should -Be 8
        }

        It 'reports CreatePlan=true with null plan fields when no open plan exists' {
            $out = & $script:ResolveScript -Repo 'o/r'
            $anchor = ([string]($out | Select-Object -First 1)) | ConvertFrom-Json
            $anchor.Mode | Should -Be 'continue-existing'
            $anchor.CreatePlan | Should -BeTrue
            $anchor.PlanNumber | Should -BeNullOrEmpty
            $anchor.PlanTitle | Should -BeNullOrEmpty
            $anchor.NextEpicNumber | Should -Be 1
        }

        It 'defaults -Mode to continue-existing when omitted' {
            $global:OpenPlanPage1 = '[{"number":42,"title":"Plan: One","created_at":"2026-03-01T10:00:00Z"}]'
            $out = & $script:ResolveScript -Repo 'o/r'
            $anchor = ([string]($out | Select-Object -First 1)) | ConvertFrom-Json
            $anchor.Mode | Should -Be 'continue-existing'
            $anchor.PlanNumber | Should -Be 42
            $anchor.CreatePlan | Should -BeFalse
        }
    }

    Context 'plan anchor resolution (new-feature-plan)' {
        BeforeEach {
            $global:GhCallLog = [System.Collections.Generic.List[string]]::new()
            $global:OpenPlanPage1 = '[{"number":42,"title":"Plan: Existing","created_at":"2026-06-01T10:00:00Z"}]'
            $global:OpenPlanPage2 = '[]'
            $global:AllIssuesPage1 = '[{"number":20,"title":"Epic 2: Something","created_at":"2026-02-01T10:00:00Z"}]'
            $global:AllIssuesPage2 = '[]'
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                $global:LASTEXITCODE = 0
                if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return }
                $cmd = $Arguments[0]
                if ($cmd -eq 'auth' -and $Arguments[1] -eq 'status') { return }
                if ($cmd -eq 'api') {
                    $global:GhCallLog.Add(($Arguments -join ' '))
                    $query = [string]$Arguments[1]
                    $page = 1
                    if ($query -match 'page=(\d+)$') { $page = [int]$Matches[1] }
                    if ($query -like '*labels=plan*') {
                        if ($page -eq 1) { return $global:OpenPlanPage1 } else { return $global:OpenPlanPage2 }
                    }
                    if ($query -like '*state=all*') {
                        if ($page -eq 1) { return $global:AllIssuesPage1 } else { return $global:AllIssuesPage2 }
                    }
                }
            }
            $global:LASTEXITCODE = 0
        }
        AfterEach {
            Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
            Remove-Variable -Name GhCallLog, OpenPlanPage1, OpenPlanPage2, AllIssuesPage1, AllIssuesPage2 -Scope Global -ErrorAction SilentlyContinue
        }

        It 'always creates the plan even when an open plan exists' {
            $out = & $script:ResolveScript -Repo 'o/r' -Mode 'new-feature-plan'
            $anchor = ([string]($out | Select-Object -First 1)) | ConvertFrom-Json
            $anchor.Mode | Should -Be 'new-feature-plan'
            $anchor.CreatePlan | Should -BeTrue
            $anchor.PlanNumber | Should -BeNullOrEmpty
            $anchor.PlanTitle | Should -BeNullOrEmpty
            $anchor.NextEpicNumber | Should -Be 3
        }
    }

    Context 'next epic number (repo-wide, open + closed)' {
        BeforeEach {
            $global:GhCallLog = [System.Collections.Generic.List[string]]::new()
            $global:OpenPlanPage1 = '[]'
            $global:OpenPlanPage2 = '[]'
            $global:AllIssuesPage1 = '[]'
            $global:AllIssuesPage2 = '[]'
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                $global:LASTEXITCODE = 0
                if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return }
                $cmd = $Arguments[0]
                if ($cmd -eq 'auth' -and $Arguments[1] -eq 'status') { return }
                if ($cmd -eq 'api') {
                    $global:GhCallLog.Add(($Arguments -join ' '))
                    $query = [string]$Arguments[1]
                    $page = 1
                    if ($query -match 'page=(\d+)$') { $page = [int]$Matches[1] }
                    if ($query -like '*labels=plan*') {
                        if ($page -eq 1) { return $global:OpenPlanPage1 } else { return $global:OpenPlanPage2 }
                    }
                    if ($query -like '*state=all*') {
                        if ($page -eq 1) { return $global:AllIssuesPage1 } else { return $global:AllIssuesPage2 }
                    }
                }
            }
            $global:LASTEXITCODE = 0
        }
        AfterEach {
            Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
            Remove-Variable -Name GhCallLog, OpenPlanPage1, OpenPlanPage2, AllIssuesPage1, AllIssuesPage2 -Scope Global -ErrorAction SilentlyContinue
        }

        It 'returns repo-wide max+1, scanning open+closed and ignoring non-epic titles' {
            $global:AllIssuesPage1 = '[{"number":3,"title":"Epic 4: A"},{"number":4,"title":"Epic 12: B"},{"number":5,"title":"Story 12.1: S"},{"number":6,"title":"Not an epic"},{"number":7,"title":"Epic 99 no colon"},{"number":8,"title":"PR sharing an epic title","pull_request":{"url":"https://api.github.com/repos/o/r/pulls/8"}}]'
            $out = & $script:ResolveScript -Repo 'o/r'
            $anchor = ([string]($out | Select-Object -First 1)) | ConvertFrom-Json
            $anchor.NextEpicNumber | Should -Be 13
            @($global:GhCallLog | Where-Object { $_ -match 'state=all' }).Count | Should -BeGreaterThan 0
        }

        It 'continues scanning onto the next page and uses its epics' {
            $page1Items = 1..100 | ForEach-Object { '{"number":' + $_ + ',"title":"Filler ' + $_ + '"}' }
            $global:AllIssuesPage1 = '[' + ($page1Items -join ',') + ']'
            $global:AllIssuesPage2 = '[{"number":200,"title":"Epic 5: Last Page"}]'
            $out = & $script:ResolveScript -Repo 'o/r'
            $anchor = ([string]($out | Select-Object -First 1)) | ConvertFrom-Json
            $anchor.NextEpicNumber | Should -Be 6
            @($global:GhCallLog | Where-Object { $_ -match 'state=all.*page=2' }).Count | Should -Be 1
        }
    }
}

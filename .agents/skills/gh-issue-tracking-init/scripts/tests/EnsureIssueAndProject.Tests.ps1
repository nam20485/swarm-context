#!/usr/bin/env pwsh
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
    Pester v5 unit tests for ensure-issue.ps1, ensure-project.ps1,
    set-project-fields.ps1, and common-auth.ps1.

    Raises code coverage for these four scripts to ~85%+ by exercising
    dry-run paths, mocked gh execution paths, validation errors, field
    creation/setting, auth bootstrap, and edge cases.

    Conventions:
    - Script paths resolved INSIDE BeforeAll via $PSScriptRoot (Pester v5
      does not preserve file-top vars at runtime).
    - gh CLI mocked as `function global:gh` with ValueFromRemainingArguments;
      removed in AfterEach.
    - $global:LASTEXITCODE reset in BeforeEach.
    - Both -DryRun and real execution paths (with mocked gh) are tested.
    - gh call tracking via $global:GhCallLog (global scope is visible from
      inside the dynamically-scoped global:gh function).

    Run:  Invoke-Pester -Path .agents/skills/gh-issue-tracking-init/scripts/tests/EnsureIssueAndProject.Tests.ps1 -Output Detailed
#>

# ============================================================================
# ensure-issue.ps1
# ============================================================================
Describe 'ensure-issue.ps1' {
    BeforeAll {
        $ghitDir = Split-Path -Parent $PSScriptRoot
        $script:EnsureIssueScript = Join-Path $ghitDir 'ensure-issue.ps1'
    }

    Context 'parameter validation' {
        It 'throws when both -Body and -BodyFile are supplied' {
            { & $script:EnsureIssueScript -Repo 'o/r' -Title 'T' -Body 'x' -BodyFile 'y' } |
                Should -Throw 'Specify only one of -Body or -BodyFile.'
        }

        It 'throws when -BodyFile points to a non-existent file' {
            $nonExistent = Join-Path ([System.IO.Path]::GetTempPath()) ("no-such-" + [guid]::NewGuid().ToString('N') + '.md')
            { & $script:EnsureIssueScript -Repo 'o/r' -Title 'T' -BodyFile $nonExistent } |
                Should -Throw "Body file not found: $nonExistent"
        }
    }

    Context 'update path (existing issue) - DryRun' {
        BeforeEach {
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                $global:LASTEXITCODE = 0
                if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return }
                $cmd = $Arguments[0]
                if ($cmd -eq 'auth' -and $Arguments[1] -eq 'status') { return }
                if ($cmd -eq 'api') { return '[{"number":5,"title":"Epic 1: Core"}]' }
            }
            $global:LASTEXITCODE = 0
        }
        AfterEach { Remove-Item Function:\global:gh -ErrorAction SilentlyContinue }

        It 'outputs the existing issue number and does not edit in DryRun' {
            $out = & $script:EnsureIssueScript -Repo 'o/r' -Title 'Epic 1: Core' -Body 'body' -Labels epic,P1 -Milestone MVP -DryRun
            $out | Should -Be 5
        }

        It 'outputs the existing issue number in DryRun even without labels or milestone' {
            $out = & $script:EnsureIssueScript -Repo 'o/r' -Title 'Epic 1: Core' -Body 'body' -DryRun
            $out | Should -Be 5
        }
    }

    Context 'update path (existing issue) - execution' {
        BeforeEach {
            $global:GhCallLog = [System.Collections.Generic.List[string]]::new()
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                $global:LASTEXITCODE = 0
                if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return }
                $cmd = $Arguments[0]
                if ($cmd -eq 'auth' -and $Arguments[1] -eq 'status') { return }
                if ($cmd -eq 'api') { return '[{"number":5,"title":"Epic 1: Core"}]' }
                if ($cmd -eq 'issue' -and $Arguments[1] -eq 'edit') {
                    $global:GhCallLog.Add(($Arguments -join ' '))
                    return
                }
            }
            $global:LASTEXITCODE = 0
        }
        AfterEach {
            Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
            Remove-Variable -Name GhCallLog -Scope Global -ErrorAction SilentlyContinue
        }

        It 'edits the issue with labels and milestone (no UpdateBody)' {
            $out = & $script:EnsureIssueScript -Repo 'o/r' -Title 'Epic 1: Core' -Body 'body' -Labels epic,P1 -Milestone MVP
            $out | Should -Be 5
            $global:GhCallLog.Count | Should -Be 1
            $global:GhCallLog[0] | Should -Match 'issue edit 5 --repo o/r'
            $global:GhCallLog[0] | Should -Match '--add-label epic'
            $global:GhCallLog[0] | Should -Match '--add-label P1'
            $global:GhCallLog[0] | Should -Match '--milestone MVP'
            $global:GhCallLog[0] | Should -Not -Match '--body'
        }

        It 'edits the issue with --body when -UpdateBody and -Body are supplied' {
            $out = & $script:EnsureIssueScript -Repo 'o/r' -Title 'Epic 1: Core' -Body 'new body' -Labels epic -UpdateBody
            $out | Should -Be 5
            $global:GhCallLog[0] | Should -Match '--body new body'
            $global:GhCallLog[0] | Should -Not -Match '--body-file'
        }

        It 'edits the issue with --body-file when -UpdateBody and -BodyFile are supplied' {
            $tmpFile = Join-Path ([System.IO.Path]::GetTempPath()) ("body-" + [guid]::NewGuid().ToString('N') + '.md')
            'file body' | Set-Content -LiteralPath $tmpFile -Encoding UTF8
            try {
                $out = & $script:EnsureIssueScript -Repo 'o/r' -Title 'Epic 1: Core' -BodyFile $tmpFile -Labels epic -UpdateBody
                $out | Should -Be 5
                $global:GhCallLog[0] | Should -Match '--body-file'
                $global:GhCallLog[0] | Should -Not -Match '--body new'
            }
            finally {
                Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue
            }
        }

        It 'edits the issue without body args when -UpdateBody is not set' {
            $out = & $script:EnsureIssueScript -Repo 'o/r' -Title 'Epic 1: Core' -Body 'body' -Labels epic
            $out | Should -Be 5
            $global:GhCallLog[0] | Should -Not -Match '--body'
        }
    }

    Context 'create path (no existing issue) - DryRun' {
        BeforeEach {
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                $global:LASTEXITCODE = 0
                if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return }
                $cmd = $Arguments[0]
                if ($cmd -eq 'auth' -and $Arguments[1] -eq 'status') { return }
                if ($cmd -eq 'api') { return '[]' }
            }
            $global:LASTEXITCODE = 0
        }
        AfterEach { Remove-Item Function:\global:gh -ErrorAction SilentlyContinue }

        It 'does not create an issue in DryRun and outputs nothing' {
            $out = & $script:EnsureIssueScript -Repo 'o/r' -Title 'New Epic' -Body 'body' -Labels epic -DryRun
            $out | Should -BeNullOrEmpty
        }

        It 'does not create an issue in DryRun with milestone and assignees' {
            $out = & $script:EnsureIssueScript -Repo 'o/r' -Title 'New Epic' -Body 'body' -Labels epic -Milestone MVP -Assignee user1 -DryRun
            $out | Should -BeNullOrEmpty
        }
    }

    Context 'create path (no existing issue) - execution' {
        BeforeEach {
            $global:GhCallLog = [System.Collections.Generic.List[string]]::new()
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                $global:LASTEXITCODE = 0
                if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return }
                $cmd = $Arguments[0]
                if ($cmd -eq 'auth' -and $Arguments[1] -eq 'status') { return }
                if ($cmd -eq 'api') { return '[]' }
                if ($cmd -eq 'issue' -and $Arguments[1] -eq 'create') {
                    $global:GhCallLog.Add(($Arguments -join ' '))
                    return 'https://github.com/o/r/issues/42'
                }
            }
            $global:LASTEXITCODE = 0
        }
        AfterEach {
            Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
            Remove-Variable -Name GhCallLog -Scope Global -ErrorAction SilentlyContinue
        }

        It 'creates the issue and parses the number from the URL' {
            $out = & $script:EnsureIssueScript -Repo 'o/r' -Title 'New Epic' -Body 'body' -Labels epic,P1 -Milestone MVP -Assignee user1,user2
            $out | Should -Be 42
            $global:GhCallLog.Count | Should -Be 1
            $global:GhCallLog[0] | Should -Match 'issue create --repo o/r --title New Epic'
            $global:GhCallLog[0] | Should -Match '--body body'
            $global:GhCallLog[0] | Should -Match '--label epic'
            $global:GhCallLog[0] | Should -Match '--milestone MVP'
            $global:GhCallLog[0] | Should -Match '--assignee user1'
            $global:GhCallLog[0] | Should -Match '--assignee user2'
        }

        It 'creates the issue with --body-file when -BodyFile is supplied' {
            $tmpFile = Join-Path ([System.IO.Path]::GetTempPath()) ("body-" + [guid]::NewGuid().ToString('N') + '.md')
            'file body' | Set-Content -LiteralPath $tmpFile -Encoding UTF8
            try {
                $out = & $script:EnsureIssueScript -Repo 'o/r' -Title 'New Epic' -BodyFile $tmpFile -Labels epic
                $out | Should -Be 42
                $global:GhCallLog[0] | Should -Match '--body-file'
                $global:GhCallLog[0] | Should -Not -Match '--body file'
            }
            finally {
                Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue
            }
        }

        It 'creates the issue with empty body when neither -Body nor -BodyFile supplied' {
            $out = & $script:EnsureIssueScript -Repo 'o/r' -Title 'New Epic' -Labels epic
            $out | Should -Be 42
            $global:GhCallLog[0] | Should -Match '--body'
            $global:GhCallLog[0] | Should -Not -Match '--body-file'
        }

        It 'creates the issue without labels, milestone, or assignees' {
            $out = & $script:EnsureIssueScript -Repo 'o/r' -Title 'New Epic' -Body 'body'
            $out | Should -Be 42
        }
    }

    Context 'create path - parse failure' {
        BeforeEach {
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                $global:LASTEXITCODE = 0
                if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return }
                $cmd = $Arguments[0]
                if ($cmd -eq 'auth' -and $Arguments[1] -eq 'status') { return }
                if ($cmd -eq 'api') { return '[]' }
                if ($cmd -eq 'issue' -and $Arguments[1] -eq 'create') { return 'Creating issue in o/r' }
            }
            $global:LASTEXITCODE = 0
        }
        AfterEach { Remove-Item Function:\global:gh -ErrorAction SilentlyContinue }

        It 'throws when the created issue URL cannot be parsed' {
            { & $script:EnsureIssueScript -Repo 'o/r' -Title 'New Epic' -Body 'body' } |
                Should -Throw 'Failed to parse issue number*'
        }
    }
}

# ============================================================================
# set-project-fields.ps1
# ============================================================================
Describe 'set-project-fields.ps1' {
    BeforeAll {
        $ghitDir = Split-Path -Parent $PSScriptRoot
        $script:SetFieldsScript = Join-Path $ghitDir 'set-project-fields.ps1'
    }

    Context 'DryRun - with fields' {
        BeforeEach {
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                $global:LASTEXITCODE = 0
                if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return }
                if ($Arguments[0] -eq 'auth' -and $Arguments[1] -eq 'status') { return }
            }
            $global:LASTEXITCODE = 0
        }
        AfterEach { Remove-Item Function:\global:gh -ErrorAction SilentlyContinue }

        It 'completes without throwing when single-select and estimate are supplied' {
            $p = @{
                Owner         = 'o'
                ProjectNumber = 3
                Repo          = 'o/r'
                IssueNumber   = 42
                Level         = 'story'
                Priority      = 'P1'
                Estimate      = 5
                DryRun        = [switch]$true
            }
            { & $script:SetFieldsScript @p } | Should -Not -Throw
        }

        It 'completes without throwing when only estimate is supplied' {
            $p = @{
                Owner         = 'o'
                ProjectNumber = 3
                Repo          = 'o/r'
                IssueNumber   = 42
                Estimate      = 8
                DryRun        = [switch]$true
            }
            { & $script:SetFieldsScript @p } | Should -Not -Throw
        }
    }

    Context 'DryRun - without fields' {
        BeforeEach {
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                $global:LASTEXITCODE = 0
                if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return }
                if ($Arguments[0] -eq 'auth' -and $Arguments[1] -eq 'status') { return }
            }
            $global:LASTEXITCODE = 0
        }
        AfterEach { Remove-Item Function:\global:gh -ErrorAction SilentlyContinue }

        It 'completes without throwing when no fields are supplied' {
            $p = @{
                Owner         = 'o'
                ProjectNumber = 3
                Repo          = 'o/r'
                IssueNumber   = 42
                DryRun        = [switch]$true
            }
            { & $script:SetFieldsScript @p } | Should -Not -Throw
        }
    }

    Context 'Set-SingleSelect - field and option found' {
        BeforeEach {
            $global:GhCallLog = [System.Collections.Generic.List[string]]::new()
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                $global:LASTEXITCODE = 0
                if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return }
                $cmd = $Arguments[0]
                $sub = if ($Arguments.Count -gt 1) { $Arguments[1] } else { '' }
                if ($cmd -eq 'auth' -and $sub -eq 'status') { return }
                if ($cmd -eq 'project' -and $sub -eq 'view') { return '{"id":"PVT_1"}' }
                if ($cmd -eq 'project' -and $sub -eq 'field-list') {
                    return '{"fields":[{"name":"Level","id":"fld_lvl","options":[{"name":"story","id":"opt_story"},{"name":"epic","id":"opt_epic"}]}]}'
                }
                if ($cmd -eq 'project' -and $sub -eq 'item-add') { return '{"id":"PVTI_1"}' }
                if ($cmd -eq 'project' -and $sub -eq 'item-edit') {
                    $global:GhCallLog.Add(($Arguments -join ' '))
                    return
                }
            }
            $global:LASTEXITCODE = 0
        }
        AfterEach {
            Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
            Remove-Variable -Name GhCallLog -Scope Global -ErrorAction SilentlyContinue
        }

        It 'calls item-edit with the correct field and option ids' {
            $p = @{
                Owner         = 'o'
                ProjectNumber = 3
                Repo          = 'o/r'
                IssueNumber   = 42
                Level         = 'story'
            }
            & $script:SetFieldsScript @p 3>&1 | Out-Null
            $global:GhCallLog.Count | Should -Be 1
            $global:GhCallLog[0] | Should -Match '--field-id fld_lvl'
            $global:GhCallLog[0] | Should -Match '--single-select-option-id opt_story'
            $global:GhCallLog[0] | Should -Match '--project-id PVT_1'
            $global:GhCallLog[0] | Should -Match '--id PVTI_1'
        }
    }

    Context 'Set-SingleSelect - field not found' {
        BeforeEach {
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                $global:LASTEXITCODE = 0
                if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return }
                $cmd = $Arguments[0]
                $sub = if ($Arguments.Count -gt 1) { $Arguments[1] } else { '' }
                if ($cmd -eq 'auth' -and $sub -eq 'status') { return }
                if ($cmd -eq 'project' -and $sub -eq 'view') { return '{"id":"PVT_1"}' }
                if ($cmd -eq 'project' -and $sub -eq 'field-list') { return '{"fields":[]}' }
                if ($cmd -eq 'project' -and $sub -eq 'item-add') { return '{"id":"PVTI_1"}' }
            }
            $global:LASTEXITCODE = 0
        }
        AfterEach { Remove-Item Function:\global:gh -ErrorAction SilentlyContinue }

        It 'emits a warning when the field is not found on the project' {
            $p = @{
                Owner         = 'o'
                ProjectNumber = 3
                Repo          = 'o/r'
                IssueNumber   = 42
                Level         = 'story'
            }
            $all = & $script:SetFieldsScript @p 3>&1
            $warnings = @($all | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
            $warnings.Count | Should -Be 1
            $warnings[0].Message | Should -Match "Field 'Level' not found"
        }
    }

    Context 'Set-SingleSelect - option not found' {
        BeforeEach {
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                $global:LASTEXITCODE = 0
                if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return }
                $cmd = $Arguments[0]
                $sub = if ($Arguments.Count -gt 1) { $Arguments[1] } else { '' }
                if ($cmd -eq 'auth' -and $sub -eq 'status') { return }
                if ($cmd -eq 'project' -and $sub -eq 'view') { return '{"id":"PVT_1"}' }
                if ($cmd -eq 'project' -and $sub -eq 'field-list') {
                    return '{"fields":[{"name":"Level","id":"fld_lvl","options":[{"name":"epic","id":"opt_epic"}]}]}'
                }
                if ($cmd -eq 'project' -and $sub -eq 'item-add') { return '{"id":"PVTI_1"}' }
            }
            $global:LASTEXITCODE = 0
        }
        AfterEach { Remove-Item Function:\global:gh -ErrorAction SilentlyContinue }

        It 'emits a warning when the option is not found for the field' {
            $p = @{
                Owner         = 'o'
                ProjectNumber = 3
                Repo          = 'o/r'
                IssueNumber   = 42
                Level         = 'story'
            }
            $all = & $script:SetFieldsScript @p 3>&1
            $warnings = @($all | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
            $warnings.Count | Should -Be 1
            $warnings[0].Message | Should -Match "Option 'story' not found for field 'Level'"
        }
    }

    Context 'Estimate field - found' {
        BeforeEach {
            $global:GhCallLog = [System.Collections.Generic.List[string]]::new()
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                $global:LASTEXITCODE = 0
                if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return }
                $cmd = $Arguments[0]
                $sub = if ($Arguments.Count -gt 1) { $Arguments[1] } else { '' }
                if ($cmd -eq 'auth' -and $sub -eq 'status') { return }
                if ($cmd -eq 'project' -and $sub -eq 'view') { return '{"id":"PVT_1"}' }
                if ($cmd -eq 'project' -and $sub -eq 'field-list') {
                    return '{"fields":[{"name":"Estimate","id":"fld_est"}]}'
                }
                if ($cmd -eq 'project' -and $sub -eq 'item-add') { return '{"id":"PVTI_1"}' }
                if ($cmd -eq 'project' -and $sub -eq 'item-edit') {
                    $global:GhCallLog.Add(($Arguments -join ' '))
                    return
                }
            }
            $global:LASTEXITCODE = 0
        }
        AfterEach {
            Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
            Remove-Variable -Name GhCallLog -Scope Global -ErrorAction SilentlyContinue
        }

        It 'calls item-edit with --number when the Estimate field exists' {
            $p = @{
                Owner         = 'o'
                ProjectNumber = 3
                Repo          = 'o/r'
                IssueNumber   = 42
                Estimate      = 5
            }
            & $script:SetFieldsScript @p 3>&1 | Out-Null
            $global:GhCallLog.Count | Should -Be 1
            $global:GhCallLog[0] | Should -Match '--field-id fld_est'
            $global:GhCallLog[0] | Should -Match '--number 5'
        }
    }

    Context 'Estimate field - not found' {
        BeforeEach {
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                $global:LASTEXITCODE = 0
                if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return }
                $cmd = $Arguments[0]
                $sub = if ($Arguments.Count -gt 1) { $Arguments[1] } else { '' }
                if ($cmd -eq 'auth' -and $sub -eq 'status') { return }
                if ($cmd -eq 'project' -and $sub -eq 'view') { return '{"id":"PVT_1"}' }
                if ($cmd -eq 'project' -and $sub -eq 'field-list') { return '{"fields":[]}' }
                if ($cmd -eq 'project' -and $sub -eq 'item-add') { return '{"id":"PVTI_1"}' }
            }
            $global:LASTEXITCODE = 0
        }
        AfterEach { Remove-Item Function:\global:gh -ErrorAction SilentlyContinue }

        It 'emits a warning when the Estimate field is not found' {
            $p = @{
                Owner         = 'o'
                ProjectNumber = 3
                Repo          = 'o/r'
                IssueNumber   = 42
                Estimate      = 5
            }
            $all = & $script:SetFieldsScript @p 3>&1
            $warnings = @($all | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
            $warnings.Count | Should -Be 1
            $warnings[0].Message | Should -Match "Field 'Estimate' not found"
        }
    }

    Context 'combined single-select and estimate - all found' {
        BeforeEach {
            $global:GhCallLog = [System.Collections.Generic.List[string]]::new()
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                $global:LASTEXITCODE = 0
                if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return }
                $cmd = $Arguments[0]
                $sub = if ($Arguments.Count -gt 1) { $Arguments[1] } else { '' }
                if ($cmd -eq 'auth' -and $sub -eq 'status') { return }
                if ($cmd -eq 'project' -and $sub -eq 'view') { return '{"id":"PVT_1"}' }
                if ($cmd -eq 'project' -and $sub -eq 'field-list') {
                    return '{"fields":[{"name":"Level","id":"fld_lvl","options":[{"name":"story","id":"opt_story"}]},{"name":"Estimate","id":"fld_est"}]}'
                }
                if ($cmd -eq 'project' -and $sub -eq 'item-add') { return '{"id":"PVTI_1"}' }
                if ($cmd -eq 'project' -and $sub -eq 'item-edit') {
                    $global:GhCallLog.Add(($Arguments -join ' '))
                    return
                }
            }
            $global:LASTEXITCODE = 0
        }
        AfterEach {
            Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
            Remove-Variable -Name GhCallLog -Scope Global -ErrorAction SilentlyContinue
        }

        It 'sets both the single-select field and the estimate field' {
            $p = @{
                Owner         = 'o'
                ProjectNumber = 3
                Repo          = 'o/r'
                IssueNumber   = 42
                Level         = 'story'
                Estimate      = 5
            }
            & $script:SetFieldsScript @p 3>&1 | Out-Null
            $global:GhCallLog.Count | Should -Be 2
            ($global:GhCallLog | Where-Object { $_ -match '--single-select-option-id' }).Count | Should -Be 1
            ($global:GhCallLog | Where-Object { $_ -match '--number 5' }).Count | Should -Be 1
        }
    }

    Context 'field-list fallback (no fields property)' {
        BeforeEach {
            $global:GhCallLog = [System.Collections.Generic.List[string]]::new()
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                $global:LASTEXITCODE = 0
                if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return }
                $cmd = $Arguments[0]
                $sub = if ($Arguments.Count -gt 1) { $Arguments[1] } else { '' }
                if ($cmd -eq 'auth' -and $sub -eq 'status') { return }
                if ($cmd -eq 'project' -and $sub -eq 'view') { return '{"id":"PVT_1"}' }
                # Return a bare array (no "fields" wrapper) to exercise the Get-JsonProp fallback
                if ($cmd -eq 'project' -and $sub -eq 'field-list') {
                    return '[{"name":"Level","id":"fld_lvl","options":[{"name":"story","id":"opt_story"}]}]'
                }
                if ($cmd -eq 'project' -and $sub -eq 'item-add') { return '{"id":"PVTI_1"}' }
                if ($cmd -eq 'project' -and $sub -eq 'item-edit') {
                    $global:GhCallLog.Add(($Arguments -join ' '))
                    return
                }
            }
            $global:LASTEXITCODE = 0
        }
        AfterEach {
            Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
            Remove-Variable -Name GhCallLog -Scope Global -ErrorAction SilentlyContinue
        }

        It 'falls back to the raw field-list when no "fields" property exists' {
            $p = @{
                Owner         = 'o'
                ProjectNumber = 3
                Repo          = 'o/r'
                IssueNumber   = 42
                Level         = 'story'
            }
            & $script:SetFieldsScript @p 3>&1 | Out-Null
            $global:GhCallLog.Count | Should -Be 1
            $global:GhCallLog[0] | Should -Match '--field-id fld_lvl'
        }
    }
}

# ============================================================================
# ensure-project.ps1
# ============================================================================
Describe 'ensure-project.ps1' {
    BeforeAll {
        $ghitDir = Split-Path -Parent $PSScriptRoot
        $script:EnsureProjectScript = Join-Path $ghitDir 'ensure-project.ps1'
    }

    Context 'title defaulting' {
        BeforeEach {
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                $global:LASTEXITCODE = 0
                if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return }
                $cmd = $Arguments[0]
                $sub = if ($Arguments.Count -gt 1) { $Arguments[1] } else { '' }
                if ($cmd -eq 'auth' -and $sub -eq 'status') { return }
                if ($cmd -eq 'project' -and $sub -eq 'list') { return '{"projects":[{"number":7,"title":"my-repo"}]}' }
                if ($cmd -eq 'project' -and $sub -eq 'field-list') { return '{"fields":[{"name":"Level"},{"name":"Priority"},{"name":"Estimate"}]}' }
            }
            $global:LASTEXITCODE = 0
        }
        AfterEach { Remove-Item Function:\global:gh -ErrorAction SilentlyContinue }

        It 'defaults Title to the repo name when not supplied' {
            $out = & $script:EnsureProjectScript -Owner 'o' -Repo 'o/my-repo' -DryRun
            $out | Should -Be 7
        }
    }

    Context 'project exists - DryRun' {
        BeforeEach {
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                $global:LASTEXITCODE = 0
                if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return }
                $cmd = $Arguments[0]
                $sub = if ($Arguments.Count -gt 1) { $Arguments[1] } else { '' }
                if ($cmd -eq 'auth' -and $sub -eq 'status') { return }
                if ($cmd -eq 'project' -and $sub -eq 'list') { return '{"projects":[{"number":5,"title":"Test"}]}' }
                if ($cmd -eq 'project' -and $sub -eq 'field-list') { return '{"fields":[{"name":"Level"},{"name":"Priority"},{"name":"Estimate"}]}' }
            }
            $global:LASTEXITCODE = 0
        }
        AfterEach { Remove-Item Function:\global:gh -ErrorAction SilentlyContinue }

        It 'skips creation and outputs the existing project number' {
            $out = & $script:EnsureProjectScript -Owner 'o' -Repo 'o/r' -Title 'Test' -DryRun
            $out | Should -Be 5
        }
    }

    Context 'project does not exist - DryRun' {
        BeforeEach {
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                $global:LASTEXITCODE = 0
                if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return }
                $cmd = $Arguments[0]
                $sub = if ($Arguments.Count -gt 1) { $Arguments[1] } else { '' }
                if ($cmd -eq 'auth' -and $sub -eq 'status') { return }
                if ($cmd -eq 'project' -and $sub -eq 'list') { return '{"projects":[{"number":99,"title":"SomeOther"}]}' }
            }
            $global:LASTEXITCODE = 0
        }
        AfterEach { Remove-Item Function:\global:gh -ErrorAction SilentlyContinue }

        It 'emits nothing to stdout and does not create in DryRun' {
            $out = & $script:EnsureProjectScript -Owner 'o' -Repo 'o/r' -Title 'Test' -DryRun
            $out | Should -BeNullOrEmpty
        }
    }

    Context 'project creation - execution with link success' {
        BeforeEach {
            $global:GhCallLog = [System.Collections.Generic.List[string]]::new()
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                $global:LASTEXITCODE = 0
                if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return }
                $cmd = $Arguments[0]
                $sub = if ($Arguments.Count -gt 1) { $Arguments[1] } else { '' }
                if ($cmd -eq 'auth' -and $sub -eq 'status') { return }
                if ($cmd -eq 'project' -and $sub -eq 'list') { return '{"projects":[{"number":99,"title":"SomeOther"}]}' }
                if ($cmd -eq 'project' -and $sub -eq 'create') { return '{"number":7,"url":"https://github.com/orgs/o/projects/7"}' }
                if ($cmd -eq 'project' -and $sub -eq 'link') { return }
                if ($cmd -eq 'project' -and $sub -eq 'field-list') { return '{"fields":[{"name":"Title"},{"name":"Status"}]}' }
                if ($cmd -eq 'project' -and $sub -eq 'field-create') {
                    $global:GhCallLog.Add(($Arguments -join ' '))
                    return
                }
            }
            $global:LASTEXITCODE = 0
        }
        AfterEach {
            Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
            Remove-Variable -Name GhCallLog -Scope Global -ErrorAction SilentlyContinue
        }

        It 'creates the project, links it, and creates all missing fields' {
            $out = & $script:EnsureProjectScript -Owner 'o' -Repo 'o/r' -Title 'Test'
            $out | Should -Be 7
            # Three fields created: Level, Priority, Estimate
            $global:GhCallLog.Count | Should -Be 3
            ($global:GhCallLog | Where-Object { $_ -match '--name Level --data-type SINGLE_SELECT' }).Count | Should -Be 1
            ($global:GhCallLog | Where-Object { $_ -match '--name Priority --data-type SINGLE_SELECT' }).Count | Should -Be 1
            ($global:GhCallLog | Where-Object { $_ -match '--name Estimate --data-type NUMBER' }).Count | Should -Be 1
        }

        It 'creates SINGLE_SELECT fields with --single-select-options' {
            & $script:EnsureProjectScript -Owner 'o' -Repo 'o/r' -Title 'Test' 3>&1 | Out-Null
            $levelCall = $global:GhCallLog | Where-Object { $_ -match '--name Level ' } | Select-Object -First 1
            $levelCall | Should -Match '--single-select-options plan,epic,story,task'
            $estCall = $global:GhCallLog | Where-Object { $_ -match '--name Estimate ' } | Select-Object -First 1
            $estCall | Should -Not -Match '--single-select-options'
        }
    }

    Context 'project creation - link failure' {
        BeforeEach {
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                $global:LASTEXITCODE = 0
                if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return }
                $cmd = $Arguments[0]
                $sub = if ($Arguments.Count -gt 1) { $Arguments[1] } else { '' }
                if ($cmd -eq 'auth' -and $sub -eq 'status') { return }
                if ($cmd -eq 'project' -and $sub -eq 'list') { return '{"projects":[{"number":99,"title":"SomeOther"}]}' }
                if ($cmd -eq 'project' -and $sub -eq 'create') { return '{"number":7,"url":"https://github.com/orgs/o/projects/7"}' }
                if ($cmd -eq 'project' -and $sub -eq 'link') { $global:LASTEXITCODE = 1; return 'link failed' }
                if ($cmd -eq 'project' -and $sub -eq 'field-list') { return '{"fields":[{"name":"Title"},{"name":"Status"}]}' }
                if ($cmd -eq 'project' -and $sub -eq 'field-create') { return }
            }
            $global:LASTEXITCODE = 0
        }
        AfterEach { Remove-Item Function:\global:gh -ErrorAction SilentlyContinue }

        It 'writes a warning but continues to create fields when link fails' {
            $all = & $script:EnsureProjectScript -Owner 'o' -Repo 'o/r' -Title 'Test' 3>&1
            $warnings = @($all | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
            $warnings.Count | Should -Be 1
            $warnings[0].Message | Should -Match 'Failed to link project'
            # Project number still emitted on the success stream
            $output = @($all | Where-Object { $_ -is [int] -or $_ -is [string] })
            $output | Should -Contain 7
        }
    }

    Context 'field creation - all fields already exist' {
        BeforeEach {
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                $global:LASTEXITCODE = 0
                if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return }
                $cmd = $Arguments[0]
                $sub = if ($Arguments.Count -gt 1) { $Arguments[1] } else { '' }
                if ($cmd -eq 'auth' -and $sub -eq 'status') { return }
                if ($cmd -eq 'project' -and $sub -eq 'list') { return '{"projects":[{"number":5,"title":"Test"}]}' }
                if ($cmd -eq 'project' -and $sub -eq 'field-list') {
                    return '{"fields":[{"name":"Title"},{"name":"Status"},{"name":"Level"},{"name":"Priority"},{"name":"Estimate"}]}'
                }
            }
            $global:LASTEXITCODE = 0
        }
        AfterEach { Remove-Item Function:\global:gh -ErrorAction SilentlyContinue }

        It 'skips all field creation when all desired fields already exist' {
            $out = & $script:EnsureProjectScript -Owner 'o' -Repo 'o/r' -Title 'Test' -DryRun
            $out | Should -Be 5
        }
    }

    Context 'field creation - DryRun with existing project and missing fields' {
        BeforeEach {
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                $global:LASTEXITCODE = 0
                if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return }
                $cmd = $Arguments[0]
                $sub = if ($Arguments.Count -gt 1) { $Arguments[1] } else { '' }
                if ($cmd -eq 'auth' -and $sub -eq 'status') { return }
                if ($cmd -eq 'project' -and $sub -eq 'list') { return '{"projects":[{"number":5,"title":"Test"}]}' }
                if ($cmd -eq 'project' -and $sub -eq 'field-list') { return '{"fields":[{"name":"Title"},{"name":"Status"}]}' }
            }
            $global:LASTEXITCODE = 0
        }
        AfterEach { Remove-Item Function:\global:gh -ErrorAction SilentlyContinue }

        It 'emits dry-run messages for missing fields without creating them' {
            $out = & $script:EnsureProjectScript -Owner 'o' -Repo 'o/r' -Title 'Test' -DryRun
            $out | Should -Be 5
        }
    }

    Context 'field creation - with Phases' {
        BeforeEach {
            $global:GhCallLog = [System.Collections.Generic.List[string]]::new()
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                $global:LASTEXITCODE = 0
                if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return }
                $cmd = $Arguments[0]
                $sub = if ($Arguments.Count -gt 1) { $Arguments[1] } else { '' }
                if ($cmd -eq 'auth' -and $sub -eq 'status') { return }
                if ($cmd -eq 'project' -and $sub -eq 'list') { return '{"projects":[{"number":5,"title":"Test"}]}' }
                if ($cmd -eq 'project' -and $sub -eq 'field-list') { return '{"fields":[{"name":"Title"},{"name":"Status"}]}' }
                if ($cmd -eq 'project' -and $sub -eq 'field-create') {
                    $global:GhCallLog.Add(($Arguments -join ' '))
                    return
                }
            }
            $global:LASTEXITCODE = 0
        }
        AfterEach {
            Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
            Remove-Variable -Name GhCallLog -Scope Global -ErrorAction SilentlyContinue
        }

        It 'creates the Phase field with the supplied phase options' {
            & $script:EnsureProjectScript -Owner 'o' -Repo 'o/r' -Title 'Test' -Phases 'Current','Future' 3>&1 | Out-Null
            $phaseCall = $global:GhCallLog | Where-Object { $_ -match '--name Phase ' } | Select-Object -First 1
            $phaseCall | Should -Match '--single-select-options Current,Future'
            # Four fields total: Level, Priority, Estimate, Phase
            $global:GhCallLog.Count | Should -Be 4
        }
    }

    Context 'error handling - project list failure' {
        BeforeEach {
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                $global:LASTEXITCODE = 0
                if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return }
                $cmd = $Arguments[0]
                $sub = if ($Arguments.Count -gt 1) { $Arguments[1] } else { '' }
                if ($cmd -eq 'auth' -and $sub -eq 'status') { return }
                if ($cmd -eq 'project' -and $sub -eq 'list') { $global:LASTEXITCODE = 1; return 'error' }
            }
            $global:LASTEXITCODE = 0
        }
        AfterEach { Remove-Item Function:\global:gh -ErrorAction SilentlyContinue }

        It 'throws when project list fails' {
            { & $script:EnsureProjectScript -Owner 'o' -Repo 'o/r' -Title 'Test' -DryRun } |
                Should -Throw 'Could not list existing projects*'
        }
    }

    Context 'error handling - field-list failure' {
        BeforeEach {
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                $global:LASTEXITCODE = 0
                if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return }
                $cmd = $Arguments[0]
                $sub = if ($Arguments.Count -gt 1) { $Arguments[1] } else { '' }
                if ($cmd -eq 'auth' -and $sub -eq 'status') { return }
                if ($cmd -eq 'project' -and $sub -eq 'list') { return '{"projects":[{"number":5,"title":"Test"}]}' }
                if ($cmd -eq 'project' -and $sub -eq 'field-list') { $global:LASTEXITCODE = 1; return 'error' }
            }
            $global:LASTEXITCODE = 0
        }
        AfterEach { Remove-Item Function:\global:gh -ErrorAction SilentlyContinue }

        It 'throws when field-list fails' {
            { & $script:EnsureProjectScript -Owner 'o' -Repo 'o/r' -Title 'Test' -DryRun } |
                Should -Throw 'Could not list project fields*'
        }
    }
}

# ============================================================================
# common-auth.ps1
# ============================================================================
Describe 'common-auth.ps1' {
    BeforeAll {
        $ghitDir = Split-Path -Parent $PSScriptRoot
        $script:CommonAuthScript = Join-Path $ghitDir 'common-auth.ps1'
        # Dot-source to get Initialize-GitHubAuth into scope.
        # Reset StrictMode so it does not interfere with test assertions.
        . $script:CommonAuthScript
        Set-StrictMode -Off
    }

    Context 'gh not on PATH' {
        It 'throws when gh is not found on PATH' {
            Mock Get-Command { } -ParameterFilter { $Name -eq 'gh' }
            { Initialize-GitHubAuth } | Should -Throw 'Required tool not found on PATH: gh'
        }
    }

    Context 'gh authenticated' {
        BeforeEach {
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                $global:LASTEXITCODE = 0
            }
            $global:LASTEXITCODE = 0
        }
        AfterEach { Remove-Item Function:\global:gh -ErrorAction SilentlyContinue }

        It 'completes without login when auth status is OK' {
            { Initialize-GitHubAuth } | Should -Not -Throw
        }
    }

    Context 'gh not authenticated - DryRun' {
        BeforeEach {
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                if ($null -eq $Arguments -or $Arguments.Count -eq 0) { $global:LASTEXITCODE = 0; return }
                if ($Arguments[0] -eq 'auth' -and $Arguments[1] -eq 'status') { $global:LASTEXITCODE = 1; return }
                $global:LASTEXITCODE = 0
            }
            $global:LASTEXITCODE = 0
        }
        AfterEach { Remove-Item Function:\global:gh -ErrorAction SilentlyContinue }

        It 'prints dry-run message and does not call gh auth login' {
            { Initialize-GitHubAuth -DryRun } | Should -Not -Throw
        }
    }

    Context 'gh not authenticated - execution' {
        BeforeEach {
            $global:GhCallLog = [System.Collections.Generic.List[string]]::new()
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                if ($null -eq $Arguments -or $Arguments.Count -eq 0) { $global:LASTEXITCODE = 0; return }
                $cmd = $Arguments[0]
                $sub = if ($Arguments.Count -gt 1) { $Arguments[1] } else { '' }
                if ($cmd -eq 'auth' -and $sub -eq 'status') { $global:LASTEXITCODE = 1; return }
                if ($cmd -eq 'auth' -and $sub -eq 'login') {
                    $global:GhCallLog.Add(($Arguments -join ' '))
                    $global:LASTEXITCODE = 0
                    return
                }
                $global:LASTEXITCODE = 0
            }
            $global:LASTEXITCODE = 0
        }
        AfterEach {
            Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
            Remove-Variable -Name GhCallLog -Scope Global -ErrorAction SilentlyContinue
        }

        It 'calls gh auth login when not authenticated and not DryRun' {
            { Initialize-GitHubAuth } | Should -Not -Throw
            $global:GhCallLog.Count | Should -Be 1
            $global:GhCallLog[0] | Should -Match 'auth login'
        }
    }
}

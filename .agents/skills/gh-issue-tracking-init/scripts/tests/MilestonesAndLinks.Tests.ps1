#!/usr/bin/env pwsh
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
    Unit tests for create-milestones.ps1, link-sub-issue.ps1, and
    set-dependency.ps1 from the gh-issue-tracking-init skill.

    create-milestones.ps1 calls `exit` in several code paths.  However,
    `exit` in a script invoked via `& $script` only exits the script's
    scope (like `return`) — it does NOT terminate the host process.  We
    therefore invoke it directly with `& $script @params 6>&1` in the same
    runspace as Pester, which allows code-coverage breakpoints to fire.
    Write-Host output is captured via the 6>&1 information-stream redirect.
    Write-Error under $ErrorActionPreference = 'Stop' (set by
    common-auth.ps1) throws a terminating ActionPreferenceStopException —
    we catch it with try/catch and assert on the exception message.

    link-sub-issue.ps1 and set-dependency.ps1 use `return` (not `exit`) and
    dot-source common.ps1, which re-defines the wrapper functions
    (Invoke-Gh, Invoke-GhJson, Get-IssueDbId, …) in the script's own scope,
    shadowing Pester Mocks.  We therefore stub `gh` directly via a caller-
    scope `function global:gh` — the same technique documented in
    GhIssueTracking.Tests.ps1 and SetProjectFields.Tests.ps1.  The real
    wrappers run and reach the underlying `& gh` calls, which dynamic
    scoping resolves to our stub.

    Run:  Invoke-Pester -Path .agents/skills/gh-issue-tracking-init/scripts/tests/MilestonesAndLinks.Tests.ps1 -Output Detailed
#>

# ---------------------------------------------------------------------------
# create-milestones.ps1
# ---------------------------------------------------------------------------

Describe 'create-milestones.ps1' {

    BeforeAll {
        $ghitDir = Split-Path -Parent $PSScriptRoot
        $script:CreateMilestonesScript = Join-Path $ghitDir 'create-milestones.ps1'
    }

    Context 'DryRun path — no existing milestones' {

        BeforeEach {
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                $global:LASTEXITCODE = 0
                if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return }
                if ($Arguments[0] -eq 'auth' -and $Arguments.Count -gt 1 -and $Arguments[1] -eq 'status') { return }
                if ($Arguments[0] -eq 'api' -and $Arguments.Count -gt 1 -and $Arguments[1] -match 'milestones\?state=all') { return '[]' }
                return
            }
            $global:LASTEXITCODE = 0
        }

        AfterEach {
            Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
        }

        It 'plans create actions for new milestones' {
            $output = & $script:CreateMilestonesScript -Repo 'o/r' -Titles @('Phase 1', 'Phase 2') -DryRun 6>&1
            ($output -join "`n") | Should -Match 'create: Phase 1'
            ($output -join "`n") | Should -Match 'create: Phase 2'
            ($output -join "`n") | Should -Match 'Dry run specified'
        }

        It 'deduplicates duplicate titles (including whitespace variants)' {
            # Include a non-duplicate title so $allTitles is an array after
            # Select-Object -Unique (a single title would be a scalar, and
            # .Count on a scalar throws under Set-StrictMode -Version Latest).
            $output = & $script:CreateMilestonesScript -Repo 'o/r' -Titles @('Phase 1', 'Phase 1', ' Phase 1 ', 'Phase 2') -DryRun 6>&1
            $createLines = @($output | Where-Object { "$_" -match 'create: Phase 1' })
            $createLines | Should -HaveCount 1 -Because 'duplicates should be deduplicated after trimming'
        }

        It 'reads titles from a file, ignoring comments and empty lines' {
            $tmpFile = Join-Path ([System.IO.Path]::GetTempPath()) ("ghit-test-titles-" + [guid]::NewGuid().ToString('N') + '.txt')
            @(
                '# This is a comment',
                '',
                'Phase A',
                '  ',
                '# Another comment',
                'Phase B'
            ) | Set-Content -LiteralPath $tmpFile -Encoding UTF8

            try {
                $output = & $script:CreateMilestonesScript -Repo 'o/r' -TitlesFile $tmpFile -DryRun 6>&1
                ($output -join "`n") | Should -Match 'create: Phase A'
                ($output -join "`n") | Should -Match 'create: Phase B'
            }
            finally {
                Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'DryRun path — existing milestones' {

        BeforeEach {
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                $global:LASTEXITCODE = 0
                if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return }
                if ($Arguments[0] -eq 'auth' -and $Arguments.Count -gt 1 -and $Arguments[1] -eq 'status') { return }
                if ($Arguments[0] -eq 'api' -and $Arguments.Count -gt 1 -and $Arguments[1] -match 'milestones\?state=all') { return '[{"title":"Phase 1","id":1},{"title":"Phase 2","id":2}]' }
                return
            }
            $global:LASTEXITCODE = 0
        }

        AfterEach {
            Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
        }

        It 'plans skip actions for existing milestones (without -SkipExisting)' {
            $output = & $script:CreateMilestonesScript -Repo 'o/r' -Titles @('Phase 1', 'Phase 3') -DryRun 6>&1
            ($output -join "`n") | Should -Match 'skip: Phase 1'
            ($output -join "`n") | Should -Match 'already exists'
            ($output -join "`n") | Should -Match 'create: Phase 3'
        }

        It 'silently skips all-existing milestones with -SkipExisting ("No milestones to create")' {
            $output = & $script:CreateMilestonesScript -Repo 'o/r' -Titles @('Phase 1', 'Phase 2') -SkipExisting -DryRun 6>&1
            ($output -join "`n") | Should -Match 'No milestones to create'
        }
    }

    Context 'error paths' {

        BeforeEach {
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                $global:LASTEXITCODE = 0
                if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return }
                if ($Arguments[0] -eq 'auth' -and $Arguments.Count -gt 1 -and $Arguments[1] -eq 'status') { return }
                return
            }
            $global:LASTEXITCODE = 0
        }

        AfterEach {
            Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
        }

        It 'errors when no titles are provided' {
            # Write-Error under $ErrorActionPreference = 'Stop' throws a
            # terminating ActionPreferenceStopException whose message
            # includes the original error text.
            $errorMsg = $null
            try {
                & $script:CreateMilestonesScript -Repo 'o/r' -DryRun 6>&1 | Out-Null
            }
            catch {
                $errorMsg = $_.Exception.Message
            }
            $errorMsg | Should -Match 'No milestone titles were provided'
        }

        It 'errors when the titles file is not found' {
            $missingFile = Join-Path ([System.IO.Path]::GetTempPath()) ("ghit-nonexistent-" + [guid]::NewGuid().ToString('N') + '.txt')
            $errorMsg = $null
            try {
                & $script:CreateMilestonesScript -Repo 'o/r' -TitlesFile $missingFile -DryRun 6>&1 | Out-Null
            }
            catch {
                $errorMsg = $_.Exception.Message
            }
            $errorMsg | Should -Match 'Titles file not found'
        }

        It 'errors when the titles file contains only comments and empty lines' {
            $tmpFile = Join-Path ([System.IO.Path]::GetTempPath()) ("ghit-test-empty-" + [guid]::NewGuid().ToString('N') + '.txt')
            @('# comment', '', '  ', '# another') | Set-Content -LiteralPath $tmpFile -Encoding UTF8

            try {
                $errorMsg = $null
                try {
                    & $script:CreateMilestonesScript -Repo 'o/r' -TitlesFile $tmpFile -DryRun 6>&1 | Out-Null
                }
                catch {
                    $errorMsg = $_.Exception.Message
                }
                $errorMsg | Should -Match 'No milestone titles were provided'
            }
            finally {
                Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'API error path' {

        BeforeEach {
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                $global:LASTEXITCODE = 0
                if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return }
                if ($Arguments[0] -eq 'auth' -and $Arguments.Count -gt 1 -and $Arguments[1] -eq 'status') { return }
                if ($Arguments[0] -eq 'api' -and $Arguments.Count -gt 1 -and $Arguments[1] -match 'milestones\?state=all') { throw 'API error: 403 Forbidden' }
                return
            }
            $global:LASTEXITCODE = 0
        }

        AfterEach {
            Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
        }

        It 'errors when the milestones API call fails' {
            # Use two titles so $allTitles is an array after Select-Object
            # -Unique (avoids .Count on scalar under strict mode).
            $errorMsg = $null
            try {
                & $script:CreateMilestonesScript -Repo 'o/r' -Titles @('Phase 1', 'Phase 2') -DryRun 6>&1 | Out-Null
            }
            catch {
                $errorMsg = $_.Exception.Message
            }
            $errorMsg | Should -Match 'Failed to fetch existing milestones'
        }
    }

    Context 'actual execution path (mocked gh)' {

        BeforeEach {
            $global:GhCalls = @()
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                $global:LASTEXITCODE = 0
                if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return }
                if ($Arguments[0] -eq 'auth' -and $Arguments.Count -gt 1 -and $Arguments[1] -eq 'status') { return }
                if ($Arguments[0] -eq 'api' -and $Arguments.Count -gt 1 -and $Arguments[1] -match 'milestones\?state=all') { return '[]' }
                if ($Arguments[0] -eq 'api' -and ($Arguments -contains '-X')) {
                    $global:GhCalls += ($Arguments -join ' ')
                    return '{"title":"created"}'
                }
                return
            }
            $global:LASTEXITCODE = 0
        }

        AfterEach {
            Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
            Remove-Item Variable:\global:GhCalls -ErrorAction SilentlyContinue
        }

        It 'creates milestones via gh api POST' {
            $output = & $script:CreateMilestonesScript -Repo 'o/r' -Titles @('Phase 1', 'Phase 2') 6>&1
            ($output -join "`n") | Should -Match "Creating milestone 'Phase 1'"
            ($output -join "`n") | Should -Match "Creating milestone 'Phase 2'"
            ($output -join "`n") | Should -Match 'Done'
            $global:GhCalls | Should -HaveCount 2
        }

        It 'passes description, due_on, and state=closed when supplied' {
            $due = [DateTime]::new(2025, 8, 1, 0, 0, 0, [DateTimeKind]::Utc)
            $output = & $script:CreateMilestonesScript -Repo 'o/r' -Titles @('Phase 1', 'Phase 2') -Description 'My desc' -DueOn $due -State 'closed' 6>&1
            $global:GhCalls | Should -HaveCount 2
            $global:GhCalls[0] | Should -Match 'description=My desc'
            $global:GhCalls[0] | Should -Match 'due_on=2025-08-01T00:00:00Z'
            $global:GhCalls[0] | Should -Match 'state=closed'
        }

        It 'skips existing milestones during actual execution (without -SkipExisting)' {
            # Override the BeforeEach stub to return existing milestones.
            Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                $global:LASTEXITCODE = 0
                if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return }
                if ($Arguments[0] -eq 'auth' -and $Arguments.Count -gt 1 -and $Arguments[1] -eq 'status') { return }
                if ($Arguments[0] -eq 'api' -and $Arguments.Count -gt 1 -and $Arguments[1] -match 'milestones\?state=all') { return '[{"title":"Phase 1","id":1},{"title":"Phase 2","id":2}]' }
                if ($Arguments[0] -eq 'api' -and ($Arguments -contains '-X')) {
                    $global:GhCalls += ($Arguments -join ' ')
                    return '{"title":"created"}'
                }
                return
            }

            $output = & $script:CreateMilestonesScript -Repo 'o/r' -Titles @('Phase 1', 'Phase 3') 6>&1
            # Phase 1 and Phase 2 are skipped (exist), only Phase 3 is created
            $global:GhCalls | Should -HaveCount 1
            $global:GhCalls[0] | Should -Match 'title=Phase 3'
            ($output -join "`n") | Should -Match "Creating milestone 'Phase 3'"
            ($output -join "`n") | Should -Match 'Done'
        }
    }

    Context 'parameter validation' {

        It 'rejects a malformed -Repo' {
            { & $script:CreateMilestonesScript -Repo 'no-slash' -Titles 'x' } | Should -Throw
        }
    }
}

# ---------------------------------------------------------------------------
# link-sub-issue.ps1
# ---------------------------------------------------------------------------
# Uses `return` (not `exit`) and dot-sources common.ps1, which shadows
# Pester Mocks.  We stub `gh` directly via `function global:gh`.
# ---------------------------------------------------------------------------

Describe 'link-sub-issue.ps1' {

    BeforeAll {
        $ghitDir = Split-Path -Parent $PSScriptRoot
        $script:LinkSubIssueScript = Join-Path $ghitDir 'link-sub-issue.ps1'
    }

    Context 'DryRun path' {

        BeforeEach {
            # Regression guard for the PR #17 behavioral contract: under -DryRun
            # the script must make ZERO gh api calls (dry-run skips discovery
            # entirely). Initialize-Auth may still run `gh auth status` (a
            # non-mutating credential check), so only `gh api` invocations are
            # recorded and asserted.
            $global:GhCalls = @()
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                $global:LASTEXITCODE = 0
                if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return }
                if ($Arguments[0] -eq 'api') { $global:GhCalls += ($Arguments -join ' ') }
                if ($Arguments[0] -eq 'auth' -and $Arguments.Count -gt 1 -and $Arguments[1] -eq 'status') { return }
                if ($Arguments[0] -eq 'api' -and $Arguments.Count -gt 1 -and $Arguments[1] -match '/sub_issues$') { return '[]' }
                if ($Arguments[0] -eq 'api' -and $Arguments.Count -gt 1 -and $Arguments[1] -match '/issues/\d+$' -and ($Arguments -contains '--jq')) { return '12345' }
                return
            }
            $global:LASTEXITCODE = 0
        }

        AfterEach {
            Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
            Remove-Item Variable:\global:GhCalls -ErrorAction SilentlyContinue
        }

        It 'makes zero gh api calls and reports the planned action' {
            $output = & $script:LinkSubIssueScript -Repo 'o/r' -ParentNumber 10 -ChildNumber 12 -DryRun 6>&1
            ($output -join "`n") | Should -Match 'Would add #12 as a sub-issue of #10'
            $global:GhCalls | Should -HaveCount 0
        }
    }

    Context 'idempotency: already linked' {

        BeforeEach {
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                $global:LASTEXITCODE = 0
                if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return }
                if ($Arguments[0] -eq 'auth' -and $Arguments.Count -gt 1 -and $Arguments[1] -eq 'status') { return }
                if ($Arguments[0] -eq 'api' -and $Arguments.Count -gt 1 -and $Arguments[1] -match '/sub_issues$') {
                    return '[{"number":12,"title":"Child"}]'
                }
                return
            }
            $global:LASTEXITCODE = 0
        }

        AfterEach {
            Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
        }

        It 'skips when the child is already a sub-issue' {
            $output = & $script:LinkSubIssueScript -Repo 'o/r' -ParentNumber 10 -ChildNumber 12 6>&1
            ($output -join "`n") | Should -Match 'already a sub-issue'
        }
    }

    Context 'actual linking (mocked gh)' {

        BeforeEach {
            $global:GhCalls = @()
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                $global:LASTEXITCODE = 0
                if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return }
                if ($Arguments[0] -eq 'auth' -and $Arguments.Count -gt 1 -and $Arguments[1] -eq 'status') { return }
                if ($Arguments[0] -eq 'api' -and $Arguments.Count -gt 1 -and $Arguments[1] -match '/sub_issues$') {
                    for ($i = 0; $i -lt $Arguments.Count; $i++) {
                        if ($Arguments[$i] -eq '-X' -and ($i + 1) -lt $Arguments.Count -and $Arguments[$i + 1] -eq 'POST') {
                            $global:GhCalls += ($Arguments -join ' ')
                            return '{"number":12}'
                        }
                    }
                    return '[]'
                }
                if ($Arguments[0] -eq 'api' -and $Arguments.Count -gt 1 -and $Arguments[1] -match '/issues/\d+$' -and ($Arguments -contains '--jq')) { return '12345' }
                return
            }
            $global:LASTEXITCODE = 0
        }

        AfterEach {
            Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
            Remove-Item Variable:\global:GhCalls -ErrorAction SilentlyContinue
        }

        It 'links the child via gh api POST with the resolved database id' {
            $output = & $script:LinkSubIssueScript -Repo 'o/r' -ParentNumber 10 -ChildNumber 12 6>&1
            ($output -join "`n") | Should -Match 'Adding #12'
            ($output -join "`n") | Should -Match 'Linked #12 under #10'
            $global:GhCalls | Should -HaveCount 1
            $global:GhCalls[0] | Should -Match 'sub_issue_id=12345'
        }
    }

    Context 'error paths' {

        BeforeEach {
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                $global:LASTEXITCODE = 0
                if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return }
                if ($Arguments[0] -eq 'auth' -and $Arguments.Count -gt 1 -and $Arguments[1] -eq 'status') { return }
                if ($Arguments[0] -eq 'api' -and $Arguments.Count -gt 1 -and $Arguments[1] -match '/sub_issues$') {
                    throw 'API error: 500'
                }
                return
            }
            $global:LASTEXITCODE = 0
        }

        AfterEach {
            Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
        }

        It 'throws when listing sub-issues fails' {
            { & $script:LinkSubIssueScript -Repo 'o/r' -ParentNumber 10 -ChildNumber 12 } | Should -Throw
        }
    }

    Context 'parameter validation' {

        It 'rejects a malformed -Repo' {
            { & $script:LinkSubIssueScript -Repo 'no-slash' -ParentNumber 1 -ChildNumber 2 } | Should -Throw
        }
    }
}

# ---------------------------------------------------------------------------
# set-dependency.ps1
# ---------------------------------------------------------------------------
# Same pattern as link-sub-issue.ps1: uses `return`, dot-sources common.ps1,
# stub `gh` directly via `function global:gh`.
# ---------------------------------------------------------------------------

Describe 'set-dependency.ps1' {

    BeforeAll {
        $ghitDir = Split-Path -Parent $PSScriptRoot
        $script:SetDependencyScript = Join-Path $ghitDir 'set-dependency.ps1'
    }

    Context 'DryRun path' {

        BeforeEach {
            # Same regression guard as link-sub-issue.ps1: zero gh api calls
            # under -DryRun (Initialize-Auth's `gh auth status` is excluded).
            $global:GhCalls = @()
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                $global:LASTEXITCODE = 0
                if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return }
                if ($Arguments[0] -eq 'api') { $global:GhCalls += ($Arguments -join ' ') }
                if ($Arguments[0] -eq 'auth' -and $Arguments.Count -gt 1 -and $Arguments[1] -eq 'status') { return }
                if ($Arguments[0] -eq 'api' -and $Arguments.Count -gt 1 -and $Arguments[1] -match '/dependencies/blocked_by$') { return '[]' }
                if ($Arguments[0] -eq 'api' -and $Arguments.Count -gt 1 -and $Arguments[1] -match '/issues/\d+$' -and ($Arguments -contains '--jq')) { return '67890' }
                return
            }
            $global:LASTEXITCODE = 0
        }

        AfterEach {
            Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
            Remove-Item Variable:\global:GhCalls -ErrorAction SilentlyContinue
        }

        It 'makes zero gh api calls and reports the planned action' {
            $output = & $script:SetDependencyScript -Repo 'o/r' -IssueNumber 14 -BlockedByNumber 12 -DryRun 6>&1
            ($output -join "`n") | Should -Match 'Would mark #14 as blocked by #12'
            $global:GhCalls | Should -HaveCount 0
        }
    }

    Context 'idempotency: already blocked' {

        BeforeEach {
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                $global:LASTEXITCODE = 0
                if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return }
                if ($Arguments[0] -eq 'auth' -and $Arguments.Count -gt 1 -and $Arguments[1] -eq 'status') { return }
                if ($Arguments[0] -eq 'api' -and $Arguments.Count -gt 1 -and $Arguments[1] -match '/dependencies/blocked_by$') {
                    return '[{"number":12,"title":"Blocker"}]'
                }
                return
            }
            $global:LASTEXITCODE = 0
        }

        AfterEach {
            Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
        }

        It 'skips when the dependency already exists' {
            $output = & $script:SetDependencyScript -Repo 'o/r' -IssueNumber 14 -BlockedByNumber 12 6>&1
            ($output -join "`n") | Should -Match 'already blocked by #12'
        }
    }

    Context 'actual dependency setting (mocked gh)' {

        BeforeEach {
            $global:GhCalls = @()
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                $global:LASTEXITCODE = 0
                if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return }
                if ($Arguments[0] -eq 'auth' -and $Arguments.Count -gt 1 -and $Arguments[1] -eq 'status') { return }
                if ($Arguments[0] -eq 'api' -and $Arguments.Count -gt 1 -and $Arguments[1] -match '/dependencies/blocked_by$') {
                    for ($i = 0; $i -lt $Arguments.Count; $i++) {
                        if ($Arguments[$i] -eq '-X' -and ($i + 1) -lt $Arguments.Count -and $Arguments[$i + 1] -eq 'POST') {
                            $global:GhCalls += ($Arguments -join ' ')
                            return '{"number":12}'
                        }
                    }
                    return '[]'
                }
                if ($Arguments[0] -eq 'api' -and $Arguments.Count -gt 1 -and $Arguments[1] -match '/issues/\d+$' -and ($Arguments -contains '--jq')) { return '67890' }
                return
            }
            $global:LASTEXITCODE = 0
        }

        AfterEach {
            Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
            Remove-Item Variable:\global:GhCalls -ErrorAction SilentlyContinue
        }

        It 'sets the dependency via gh api POST with the resolved database id' {
            $output = & $script:SetDependencyScript -Repo 'o/r' -IssueNumber 14 -BlockedByNumber 12 6>&1
            ($output -join "`n") | Should -Match 'Marking #14 as blocked by #12'
            ($output -join "`n") | Should -Match '#14 is now blocked by #12'
            $global:GhCalls | Should -HaveCount 1
            $global:GhCalls[0] | Should -Match 'issue_id=67890'
        }
    }

    Context 'error paths' {

        BeforeEach {
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                $global:LASTEXITCODE = 0
                if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return }
                if ($Arguments[0] -eq 'auth' -and $Arguments.Count -gt 1 -and $Arguments[1] -eq 'status') { return }
                if ($Arguments[0] -eq 'api' -and $Arguments.Count -gt 1 -and $Arguments[1] -match '/dependencies/blocked_by$') {
                    throw 'API error: 500'
                }
                return
            }
            $global:LASTEXITCODE = 0
        }

        AfterEach {
            Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
        }

        It 'throws when listing dependencies fails' {
            { & $script:SetDependencyScript -Repo 'o/r' -IssueNumber 14 -BlockedByNumber 12 } | Should -Throw
        }
    }

    Context 'parameter validation' {

        It 'rejects a malformed -Repo' {
            { & $script:SetDependencyScript -Repo 'no-slash' -IssueNumber 1 -BlockedByNumber 2 } | Should -Throw
        }
    }
}

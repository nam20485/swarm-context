#!/usr/bin/env pwsh
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
    Pester tests for the gh-issue-tracking-init skill's operation scripts.

    These cover the mockable helper logic in common.ps1 and per-script contracts
    (parsing, -DryRun surface, and -Repo validation). Full end-to-end behavior is
    exercised by the user-run smoke test against a throwaway repo (see README.md),
    because gh is a native command and the write paths mutate a real repo.

    Run:  Invoke-Pester -Path .agents/skills/gh-issue-tracking-init/scripts/tests
#>

$ghitDir = Split-Path -Parent $PSScriptRoot
$opScripts = @(
    'ensure-labels.ps1', 'ensure-project.ps1', 'ensure-issue.ps1',
    'link-sub-issue.ps1', 'set-dependency.ps1', 'set-project-fields.ps1'
)
$allScripts = @('common.ps1') + $opScripts

$repoValidationCases = @(
    @{ Name = 'ensure-labels.ps1'; Splat = @{ Repo = 'no-slash' } }
    @{ Name = 'ensure-project.ps1'; Splat = @{ Owner = 'o'; Repo = 'no-slash' } }
    @{ Name = 'ensure-issue.ps1'; Splat = @{ Repo = 'no-slash'; Title = 't' } }
    @{ Name = 'link-sub-issue.ps1'; Splat = @{ Repo = 'no-slash'; ParentNumber = 1; ChildNumber = 2 } }
    @{ Name = 'set-dependency.ps1'; Splat = @{ Repo = 'no-slash'; IssueNumber = 1; BlockedByNumber = 2 } }
    @{ Name = 'set-project-fields.ps1'; Splat = @{ Owner = 'o'; ProjectNumber = 1; Repo = 'no-slash'; IssueNumber = 2 } }
)

BeforeAll {
    $script:GhitDir = Split-Path -Parent $PSScriptRoot
    # skill root = parent of scripts/ (holds assets/, references/, ...)
    $script:SkillDir = Split-Path -Parent $script:GhitDir
    . (Join-Path $script:GhitDir 'common.ps1')
}

Describe 'common.ps1 helpers' {

    Context 'Get-RepoParts' {
        It 'splits an owner/repo string' {
            $p = Get-RepoParts -Repo 'nam20485/SupportAssistant'
            $p.Owner | Should -Be 'nam20485'
            $p.Name | Should -Be 'SupportAssistant'
        }
        It 'throws on a malformed repo' {
            { Get-RepoParts -Repo 'not-a-repo' } | Should -Throw
        }
    }

    Context 'Find-IssueNumberByTitle' {
        It 'returns the number for an exact title match (ignoring partial matches)' {
            Mock Invoke-GhJson {
                @(
                    [pscustomobject]@{ number = 6; title = 'Epic 1: Foundations (extended)' }
                    [pscustomobject]@{ number = 5; title = 'Epic 1: Foundations' }
                )
            }
            Find-IssueNumberByTitle -Repo 'o/r' -Title 'Epic 1: Foundations' | Should -Be 5
        }
        It 'returns null when only partial matches exist' {
            Mock Invoke-GhJson { @([pscustomobject]@{ number = 6; title = 'Epic 1: Foundations (extended)' }) }
            Find-IssueNumberByTitle -Repo 'o/r' -Title 'Epic 1: Foundations' | Should -BeNullOrEmpty
        }
        It 'ignores pull requests that share the issue title' {
            # The REST issues endpoint returns both issues and PRs; a PR with the
            # same title as the target issue must not be matched.
            Mock Invoke-GhJson {
                @(
                    [pscustomobject]@{ number = 9; title = 'Epic 1: Foundations'; pull_request = @{ url = 'https://api.github.com/repos/o/r/pulls/9' } }
                    [pscustomobject]@{ number = 5; title = 'Epic 1: Foundations' }
                )
            }
            Find-IssueNumberByTitle -Repo 'o/r' -Title 'Epic 1: Foundations' | Should -Be 5
        }
        It 'does not crash on malformed elements missing the title property' {
            # Under Set-StrictMode -Version Latest, a malformed API element lacking
            # `title` must be skipped, not crash the lookup.
            Mock Invoke-GhJson {
                @(
                    [pscustomobject]@{ number = 11 },
                    $null,
                    [pscustomobject]@{ number = 5; title = 'Epic 1: Foundations' }
                )
            }
            Find-IssueNumberByTitle -Repo 'o/r' -Title 'Epic 1: Foundations' | Should -Be 5
        }
        It 'returns null when the search is empty' {
            Mock Invoke-GhJson { $null }
            Find-IssueNumberByTitle -Repo 'o/r' -Title 'Anything' | Should -BeNullOrEmpty
        }
    }

    Context 'Get-IssueDbId' {
        It 'returns the numeric database id as a long' {
            Mock Invoke-Gh { '246813' }
            $id = Get-IssueDbId -Repo 'o/r' -Number 7
            $id | Should -Be 246813
            $id | Should -BeOfType [long]
        }
        It 'returns a long when gh reports an id greater than Int32.MaxValue' {
            # GitHub global issue database IDs now exceed Int32.MaxValue (2,147,483,647);
            # a naive [int] cast throws "Value was either too large or too small for an Int32".
            Mock Invoke-Gh { '4916360172' }
            { Get-IssueDbId -Repo 'o/r' -Number 7 } | Should -Not -Throw
            $id = Get-IssueDbId -Repo 'o/r' -Number 7
            $id | Should -Be 4916360172
            $id | Should -BeOfType [long]
        }
    }

    Context 'Invoke-GhJson' {
        It 'parses JSON stdout into objects' {
            Mock Invoke-Gh { '{"number":42,"title":"x"}' }
            (Invoke-GhJson api 'repos/o/r/issues/42').number | Should -Be 42
        }
    }

    Context 'Initialize-LogFile + Write-Log' {
        # These tests create real files under a per-test temp dir and must isolate
        # $env:GHIT_LOG_FILE so they never affect the other Contexts (which rely on
        # Write-Log being a silent no-op).
        BeforeEach {
            $script:SavedLogFile = $env:GHIT_LOG_FILE
            $env:GHIT_LOG_FILE = $null
            $script:TempLogDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ghit-test-" + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $script:TempLogDir -Force | Out-Null
        }
        AfterEach {
            $env:GHIT_LOG_FILE = $script:SavedLogFile
            if (Test-Path -LiteralPath $script:TempLogDir) {
                Remove-Item -LiteralPath $script:TempLogDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'creates a timestamped logfile under the given repo root' {
            $path = Initialize-LogFile -RepoSlug 'my-repo' -RepoRoot $script:TempLogDir -Repo 'o/my-repo'
            $path | Should -Not -BeNullOrEmpty
            Test-Path -LiteralPath $path | Should -BeTrue
            (Split-Path -Leaf $path) | Should -Match '^gh-init-my-repo-\d{8}T\d{6}Z\.log$'
        }

        It 'sets $env:GHIT_LOG_FILE to the created path' {
            $path = Initialize-LogFile -RepoSlug 'my-repo' -RepoRoot $script:TempLogDir -Repo 'o/my-repo'
            $env:GHIT_LOG_FILE | Should -Be $path
        }

        It 'writes a metadata header recording repo, local path, rev, and ref' {
            $path = Initialize-LogFile -RepoSlug 'my-repo' -RepoRoot $script:TempLogDir -Repo 'o/my-repo'
            $content = Get-Content -LiteralPath $path -Raw
            $content | Should -Match '# Repository : o/my-repo'
            $content | Should -Match ('# Local path : ' + [regex]::Escape((Resolve-Path $script:TempLogDir).Path))
            $content | Should -Match '# Git rev    :'
            $content | Should -Match '# Git ref    :'
            $content | Should -Match '# OS/PS      :'
        }

        It 'records (unknown) rev/ref when the repo root is not a git repo' {
            # A fresh temp dir is not a git repo, so rev/ref must fall back gracefully.
            $path = Initialize-LogFile -RepoSlug 'my-repo' -RepoRoot $script:TempLogDir -Repo 'o/my-repo'
            $content = Get-Content -LiteralPath $path -Raw
            # Either the real rev (if git somehow resolves) or (unknown); both are valid
            # outcomes. We assert the line exists and is non-empty.
            $content | Should -Match '# Git rev    : .+'
        }

        It 'uses (unspecified) for the repository label when -Repo is omitted' {
            $path = Initialize-LogFile -RepoSlug 'my-repo' -RepoRoot $script:TempLogDir
            $content = Get-Content -LiteralPath $path -Raw
            $content | Should -Match '# Repository : \(unspecified\)'
        }

        It 'throws when the repo root does not exist' {
            { Initialize-LogFile -RepoSlug 'x' -RepoRoot (Join-Path $script:TempLogDir 'does-not-exist') } | Should -Throw
        }

        It 'sanitizes the slug for filename safety' {
            $path = Initialize-LogFile -RepoSlug 'bad/slug with spaces!' -RepoRoot $script:TempLogDir -Repo 'o/r'
            (Split-Path -Leaf $path) | Should -Match '^gh-init-bad-slug-with-spaces--\d{8}T\d{6}Z\.log$'
        }

        It 'Write-Log is a silent no-op when no log file is initialized' {
            $env:GHIT_LOG_FILE = $null
            { Write-Log -Message 'should not throw' } | Should -Not -Throw
        }

        It 'Write-Log appends a timestamped, op-tagged line when initialized' {
            $path = Initialize-LogFile -RepoSlug 'my-repo' -RepoRoot $script:TempLogDir -Repo 'o/my-repo'
            Write-Log -Op 'TEST' -Message 'hello world'
            $lines = Get-Content -LiteralPath $path
            # Header is 8 lines (7 metadata + 1 blank); the appended line follows.
            # Force an array with @() so .Count is safe under Set-StrictMode.
            $matched = @($lines | Where-Object { $_ -match '^\d{2}:\d{2}:\d{2}\.\d{3}Z \[TEST\] hello world$' })
            $matched.Count | Should -Be 1
        }

        It 'Write-Step / Write-Ok / Write-Skip / Write-DryRun mirror to the log' {
            $path = Initialize-LogFile -RepoSlug 'my-repo' -RepoRoot $script:TempLogDir -Repo 'o/my-repo'
            Write-Step 'step message'
            Write-Ok 'ok message'
            Write-Skip 'skip message'
            Write-DryRun 'dryrun message'
            $content = Get-Content -LiteralPath $path -Raw
            $content | Should -Match '\[STEP\] step message'
            $content | Should -Match '\[OK\] ok message'
            $content | Should -Match '\[SKIP\] skip message'
            $content | Should -Match '\[DRYRUN\] dryrun message'
        }

        It 'Invoke-Gh logs the command and exit code on success' {
            # Stub the underlying gh so Invoke-Gh (real) succeeds and logs.
            function global:gh { $global:LASTEXITCODE = 0; return 'ok-output' }
            $global:LASTEXITCODE = 0
            $path = Initialize-LogFile -RepoSlug 'my-repo' -RepoRoot $script:TempLogDir -Repo 'o/my-repo'
            $out = Invoke-Gh api 'repos/o/r'
            $out | Should -Be 'ok-output'
            $content = Get-Content -LiteralPath $path -Raw
            $content | Should -Match '\[gh\] INVOKING: gh api repos/o/r'
            $content | Should -Match '\[gh\] OK \(exit 0\): gh api repos/o/r'
            Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
        }

        It 'Invoke-Gh logs the failure and rethrows on non-zero exit' {
            function global:gh { $global:LASTEXITCODE = 2; return $null }
            $global:LASTEXITCODE = 2
            $path = Initialize-LogFile -RepoSlug 'my-repo' -RepoRoot $script:TempLogDir -Repo 'o/my-repo'
            { Invoke-Gh api 'fail' } | Should -Throw
            $content = Get-Content -LiteralPath $path -Raw
            $content | Should -Match '\[gh\] FAILED \(exit 2\): gh api fail'
            Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
        }
    }
}

Describe 'label taxonomy (labels.json)' {
    It 'is valid JSON and contains the canonical taxonomy' {
        $labels = Get-Content (Join-Path $SkillDir 'assets/labels.json') -Raw | ConvertFrom-Json
        $names = @($labels.name)
        foreach ($expected in @('plan', 'epic', 'story', 'task', 'P0', 'P1', 'P2', 'P3', 'blocked', 'needs-review', 'wontfix')) {
            $names | Should -Contain $expected
        }
    }
    It 'does not include workflow-state labels (those live in the Project Status field)' {
        $labels = Get-Content (Join-Path $SkillDir 'assets/labels.json') -Raw | ConvertFrom-Json
        $names = @($labels.name)
        $names | Should -Not -Contain 'in-progress'
        $names | Should -Not -Contain 'done'
    }
}

Describe 'operation script contracts' {

    It 'parses without errors: <_>' -ForEach $allScripts {
        $path = Join-Path $GhitDir $_
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors) | Out-Null
        $errors | Should -BeNullOrEmpty
    }

    It 'exposes a -DryRun switch: <_>' -ForEach $opScripts {
        $path = Join-Path $GhitDir $_
        (Get-Command $path).Parameters.ContainsKey('DryRun') | Should -BeTrue
    }

    It 'rejects a malformed -Repo: <Name>' -ForEach $repoValidationCases {
        $path = Join-Path $GhitDir $Name
        { & $path @Splat } | Should -Throw
    }
}

Describe 'self-containment' {
    It 'vendors common-auth.ps1, import-labels.ps1, and create-milestones.ps1 locally' {
        foreach ($f in @('common-auth.ps1', 'import-labels.ps1', 'create-milestones.ps1')) {
            Test-Path -LiteralPath (Join-Path $GhitDir $f) | Should -BeTrue
        }
    }
}

Describe 'ensure-project.ps1 stdout contract (F1: project number on success stream)' {
    # ensure-project.ps1 must Write-Output its project number so composing drivers can
    # capture it via $(). The script re-dot-sources common.ps1 in its own scope when
    # invoked, which would shadow Pester Mocks on the wrapper functions — but the script
    # never defines its own `gh` function, so a caller-scope `function gh` intercepts the
    # underlying `& gh` calls via PowerShell dynamic scoping. We stub `gh` that way.

    BeforeAll {
        $script:ProjectScriptPath = Join-Path $GhitDir 'ensure-project.ps1'
    }

    It 'emits the project number to the success stream when the project already exists' {
        function gh {
            param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
            $global:LASTEXITCODE = 0
            if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return }
            $cmd = $Arguments[0]
            $sub = if ($Arguments.Count -gt 1) { $Arguments[1] } else { '' }
            if ($cmd -eq 'auth' -and $sub -eq 'status') { return }
            if ($cmd -eq 'project' -and $sub -eq 'list') { return '{"projects":[{"number":5,"title":"Test"}]}' }
            # Real projects always have built-in fields (Title, Status); return a realistic field-list.
            if ($cmd -eq 'project' -and $sub -eq 'field-list') { return '{"fields":[{"name":"Title"},{"name":"Status"}]}' }
            return
        }
        $global:LASTEXITCODE = 0
        # Capture ONLY the success stream (Write-Output); Write-Host status goes to console.
        $out = & $script:ProjectScriptPath -Owner 'o' -Repo 'o/r' -Title 'Test' -DryRun
        $out | Should -Be 5
    }

    It 'emits nothing to the success stream in DryRun when the project does not yet exist' {
        function gh {
            param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
            $global:LASTEXITCODE = 0
            if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return }
            $cmd = $Arguments[0]
            $sub = if ($Arguments.Count -gt 1) { $Arguments[1] } else { '' }
            if ($cmd -eq 'auth' -and $sub -eq 'status') { return }
            # Another project exists with a different title, so the target is "not found".
            if ($cmd -eq 'project' -and $sub -eq 'list') { return '{"projects":[{"number":99,"title":"SomeOther"}]}' }
            return
        }
        $global:LASTEXITCODE = 0
        $out = & $script:ProjectScriptPath -Owner 'o' -Repo 'o/r' -Title 'Test' -DryRun
        $out | Should -BeNullOrEmpty
    }
}

# Script-scope test data for the Get-JsonProp -ForEach block below. Must be defined BEFORE the
# Describe that consumes it, because Pester 5 evaluates -ForEach data at discovery time (which
# runs top-to-bottom through the file), before any BeforeAll runs.
$getJsonPropSources = @('ensure-project.ps1', 'set-project-fields.ps1')

Describe 'Get-JsonProp edge cases (null-value guard + empty-array preservation)' {
    # Get-JsonProp is defined identically in ensure-project.ps1 and set-project-fields.ps1.
    # We extract the real function body via the PowerShell AST and invoke it directly so the
    # tests exercise production code, not a copy.
    # NOTE: $getJsonPropSources is defined at script scope (below) because Pester 5 evaluates
    # -ForEach data at discovery time, before BeforeAll runs.
    BeforeAll {
        function script:Get-FunctionScriptBlock {
            param([string]$FileName, [string]$FunctionName)
            $path = Join-Path $GhitDir $FileName
            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
            $fn = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $FunctionName
            }, $true) | Select-Object -First 1
            return $fn.Body.GetScriptBlock()
        }
    }

    It 'returns scalar null (not a 1-element null array) when the JSON value is null: <_>' -ForEach $getJsonPropSources {
        $sb = Get-FunctionScriptBlock -FileName $_ -FunctionName 'Get-JsonProp'
        # Get-JsonProp consumes ConvertFrom-Json output (PSCustomObject), not Hashtable.
        $obj = [pscustomobject]@{ present = $null }
        $val = & $sb $obj 'present'
        # Discriminator: for scalar $null, `$null -eq $val` is $true; for a 1-element array
        # wrapping $null (the old `, $prop.Value` behavior), it is $false.
        $null -eq $val | Should -BeTrue
    }

    It 'preserves an empty array instead of unrolling it to null: <_>' -ForEach $getJsonPropSources {
        $sb = Get-FunctionScriptBlock -FileName $_ -FunctionName 'Get-JsonProp'
        $obj = [pscustomobject]@{ items = @() }
        $val = & $sb $obj 'items'
        $val.Count | Should -Be 0
        # An empty array is NOT scalar null.
        $null -eq $val | Should -BeFalse
    }

    It 'returns null when the object is null: <_>' -ForEach $getJsonPropSources {
        $sb = Get-FunctionScriptBlock -FileName $_ -FunctionName 'Get-JsonProp'
        $val = & $sb $null 'anything'
        $null -eq $val | Should -BeTrue
    }

    It 'returns null when the property is absent: <_>' -ForEach $getJsonPropSources {
        $sb = Get-FunctionScriptBlock -FileName $_ -FunctionName 'Get-JsonProp'
        $obj = [pscustomobject]@{ other = 1 }
        $val = & $sb $obj 'missing'
        $null -eq $val | Should -BeTrue
    }

    It 'returns a scalar value intact: <_>' -ForEach $getJsonPropSources {
        $sb = Get-FunctionScriptBlock -FileName $_ -FunctionName 'Get-JsonProp'
        $obj = [pscustomobject]@{ n = 42 }
        $val = & $sb $obj 'n'
        $val | Should -Be 42
    }

    It 'returns a non-empty array intact: <_>' -ForEach $getJsonPropSources {
        $sb = Get-FunctionScriptBlock -FileName $_ -FunctionName 'Get-JsonProp'
        $obj = [pscustomobject]@{ arr = @(1, 2, 3) }
        $val = & $sb $obj 'arr'
        $val.Count | Should -Be 3
    }
}

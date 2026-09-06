#!/usr/bin/env pwsh
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
    Unit tests for update-powershell-standard.ps1 from the
    update-powershell-standard skill.

    The script is exercised exclusively via -SourceFile fixtures against a
    scratch repo tree — no network access, no writes to the real
    .agents/rules/ hierarchy. Each It gets a fresh scratch RepoRoot.

    Run:  Invoke-Pester -Path .agents/skills/update-powershell-standard/scripts/tests -Output Detailed
#>

Describe 'update-powershell-standard.ps1' {

    BeforeAll {
        $skillScriptsDir = Split-Path -Parent $PSScriptRoot
        $script:UpdateScript = Join-Path $skillScriptsDir 'update-powershell-standard.ps1'
        $script:FixtureDir = Join-Path ([System.IO.Path]::GetTempPath()) ("psestd-fixture-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:FixtureDir -Force | Out-Null

        # Full 24-key fixture: sections 0-20 (numeric keys) plus the three
        # named sections, matching $sectionFileMap's inventory exactly.
        $sections = foreach ($n in 0..20) {
            "## $n. Section $n`ncontent $n"
        }
        foreach ($named in 'Definition of done', 'Lineage', 'Deeper guidance') {
            $sections += "## $named`nnamed content"
        }
        $script:FixtureBody = ($sections -join "`n`n")

        # Fixture with a fenced '## ' line inside section 1 — must NOT split.
        # Single-quoted here-string: a double-quoted one would escape-process
        # the backtick fence lines (`` -> literal, trailing ` + newline ->
        # line continuation) and corrupt the fixture.
        $fencedBody = @'
# PowerShell Engineer Standard

**Version:** v2.0.0

## 1. Canonical shape

Real content.

```
## not a heading (inside a fence)
```

## 2. Naming

content 2
'@
        foreach ($n in @(0, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20)) {
            $fencedBody += "`n`n## $n. Section $n`ncontent $n"
        }
        foreach ($named in 'Definition of done', 'Lineage', 'Deeper guidance') {
            $fencedBody += "`n`n## $named`nnamed content"
        }
        $script:FencedFixture = Join-Path $script:FixtureDir 'fenced.md'
        Set-Content -LiteralPath $script:FencedFixture -Value $fencedBody -Encoding utf8NoBOM -NoNewline

        $script:ExpectedTopicFiles = @(
            '00-non-negotiables.md', '01-function-authoring.md', '02-pipeline-errors-safety.md',
            '03-help-and-prose.md', '04-testing-pester.md', '05-modules-packaging.md',
            '06-performance.md', '07-security.md', '08-platform-style-encoding.md',
            '09-output-logging-files.md', '99-definition-of-done.md'
        )
        # Accumulator for scratch repos created in BeforeEach (single BeforeAll:
        # a second BeforeAll block would break $script: visibility in Pester 5).
        $script:ScratchCleanup = @()
    }
    AfterAll {
        Remove-Item -LiteralPath $script:FixtureDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    BeforeEach {
        # Fresh scratch repo per test: .agents/rules/ + a pre-stamped index.
        $script:Repo = Join-Path ([System.IO.Path]::GetTempPath()) ("psestd-repo-" + [guid]::NewGuid().ToString('N'))
        $rulesDir = Join-Path $script:Repo '.agents/rules/powershell'
        New-Item -ItemType Directory -Path $rulesDir -Force | Out-Null
        $script:IndexPath = Join-Path $script:Repo '.agents/rules/powershell.md'
        Set-Content -LiteralPath $script:IndexPath -Value "# Index`n`n**Upstream version:** 1.0.0`n`nHouse content.`n" -Encoding utf8NoBOM -NoNewline
        $script:ScratchCleanup += $script:Repo
    }

    AfterEach {
        foreach ($dir in $script:ScratchCleanup) {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
        $script:ScratchCleanup = @()
    }

    Context 'fixtures and helpers' {

        It 'builds a full fixture covering every mapped section key' {
            $fixture = Join-Path $script:FixtureDir 'full.md'
            Set-Content -LiteralPath $fixture -Value "# Title`n`n**Version:** v9.9.9`n`nPreamble marker text.`n`n$($script:FixtureBody)`n" -Encoding utf8NoBOM -NoNewline
            $fixture | Should -Exist
            (Get-Content -LiteralPath $fixture -Raw) | Should -Match '\*\*Version:\*\* v9\.9\.9'
        }
    }

    Context 'full refresh' {

        It 'writes all 11 topic files, stamps the index, and reports Refreshed' {
            $fixture = Join-Path $script:FixtureDir 'full.md'
            Set-Content -LiteralPath $fixture -Value "# Title`n`n**Version:** v9.9.9`n`nPreamble marker text.`n`n$($script:FixtureBody)`n" -Encoding utf8NoBOM -NoNewline

            $summary = & $script:UpdateScript -SourceFile $fixture -RepoRoot $script:Repo

            $summary.Status | Should -Be 'Refreshed'
            $summary.UpstreamVersion | Should -Be '9.9.9'
            $summary.PreviousVersion | Should -Be '1.0.0'
            $summary.FilesWritten | Should -Be 11
            $summary.IndexUpdated | Should -BeTrue

            foreach ($name in $script:ExpectedTopicFiles) {
                $path = Join-Path $script:Repo ".agents/rules/powershell/$name"
                $path | Should -Exist
            }

            (Get-Content -LiteralPath $script:IndexPath -Raw) | Should -Match '\*\*Upstream version:\*\* 9\.9\.9'
        }

        It 'stamps every topic file with the generated-by header' {
            $fixture = Join-Path $script:FixtureDir 'full.md'
            Set-Content -LiteralPath $fixture -Value "# Title`n`n**Version:** v9.9.9`n`nPreamble marker text.`n`n$($script:FixtureBody)`n" -Encoding utf8NoBOM -NoNewline

            $null = & $script:UpdateScript -SourceFile $fixture -RepoRoot $script:Repo

            $topic = Get-Content -LiteralPath (Join-Path $script:Repo '.agents/rules/powershell/07-security.md') -Raw
            $topic | Should -Match 'Generated by update-powershell-standard'
            $topic | Should -Match 'DO NOT EDIT'
        }

        It 'places the preamble only in 00-non-negotiables.md' {
            $fixture = Join-Path $script:FixtureDir 'full.md'
            Set-Content -LiteralPath $fixture -Value "# Title`n`n**Version:** v9.9.9`n`nPreamble marker text.`n`n$($script:FixtureBody)`n" -Encoding utf8NoBOM -NoNewline

            $null = & $script:UpdateScript -SourceFile $fixture -RepoRoot $script:Repo

            $first = Get-Content -LiteralPath (Join-Path $script:Repo '.agents/rules/powershell/00-non-negotiables.md') -Raw
            $second = Get-Content -LiteralPath (Join-Path $script:Repo '.agents/rules/powershell/01-function-authoring.md') -Raw
            $last = Get-Content -LiteralPath (Join-Path $script:Repo '.agents/rules/powershell/99-definition-of-done.md') -Raw
            $first | Should -Match 'Preamble marker text'
            $second | Should -Not -Match 'Preamble marker text'
            $last | Should -Not -Match 'Preamble marker text'
        }
    }

    Context 'no-op and idempotency' {

        It 'no-ops when the recorded version matches upstream' {
            $fixture = Join-Path $script:FixtureDir 'full.md'
            Set-Content -LiteralPath $fixture -Value "# Title`n`n**Version:** v9.9.9`n`nPreamble marker text.`n`n$($script:FixtureBody)`n" -Encoding utf8NoBOM -NoNewline
            $null = & $script:UpdateScript -SourceFile $fixture -RepoRoot $script:Repo
            (Get-Content -LiteralPath $script:IndexPath -Raw) | Should -Match '\*\*Upstream version:\*\* 9\.9\.9'

            # Delete one topic file: the no-op path must NOT regenerate anything.
            Remove-Item -LiteralPath (Join-Path $script:Repo '.agents/rules/powershell/07-security.md') -Force

            $summary = & $script:UpdateScript -SourceFile $fixture -RepoRoot $script:Repo

            $summary.Status | Should -Be 'UpToDate'
            $summary.UpdateAvailable | Should -BeFalse
            $summary.FilesWritten | Should -Be 0
            Join-Path $script:Repo '.agents/rules/powershell/07-security.md' | Should -Not -Exist
        }

        It 'with -Force re-splits at the same version and reports unchanged files' {
            $fixture = Join-Path $script:FixtureDir 'full.md'
            Set-Content -LiteralPath $fixture -Value "# Title`n`n**Version:** v9.9.9`n`nPreamble marker text.`n`n$($script:FixtureBody)`n" -Encoding utf8NoBOM -NoNewline
            $null = & $script:UpdateScript -SourceFile $fixture -RepoRoot $script:Repo

            # Second run with -Force: identical content -> write-only-on-change.
            $summary = & $script:UpdateScript -SourceFile $fixture -RepoRoot $script:Repo -Force

            $summary.Status | Should -Be 'Refreshed'
            $summary.UpdateAvailable | Should -BeFalse
            $summary.FilesWritten | Should -Be 0
            $summary.FilesUnchanged | Should -Be 11
        }

        It 'regenerates a missing topic file under -Force' {
            $fixture = Join-Path $script:FixtureDir 'full.md'
            Set-Content -LiteralPath $fixture -Value "# Title`n`n**Version:** v9.9.9`n`nPreamble marker text.`n`n$($script:FixtureBody)`n" -Encoding utf8NoBOM -NoNewline
            $null = & $script:UpdateScript -SourceFile $fixture -RepoRoot $script:Repo
            Remove-Item -LiteralPath (Join-Path $script:Repo '.agents/rules/powershell/07-security.md') -Force

            $summary = & $script:UpdateScript -SourceFile $fixture -RepoRoot $script:Repo -Force

            $summary.FilesWritten | Should -Be 1
            Join-Path $script:Repo '.agents/rules/powershell/07-security.md' | Should -Exist
        }
    }

    Context 'CheckOnly' {

        It 'reports the available update without writing anything' {
            $fixture = Join-Path $script:FixtureDir 'full.md'
            Set-Content -LiteralPath $fixture -Value "# Title`n`n**Version:** v9.9.9`n`nPreamble marker text.`n`n$($script:FixtureBody)`n" -Encoding utf8NoBOM -NoNewline

            $summary = & $script:UpdateScript -SourceFile $fixture -RepoRoot $script:Repo -CheckOnly

            $summary.Status | Should -Be 'CheckOnly'
            $summary.UpdateAvailable | Should -BeTrue
            $summary.CheckOnly | Should -BeTrue
            $summary.FilesWritten | Should -Be 0
            foreach ($name in $script:ExpectedTopicFiles) {
                Join-Path $script:Repo ".agents/rules/powershell/$name" | Should -Not -Exist
            }
            (Get-Content -LiteralPath $script:IndexPath -Raw) | Should -Match '\*\*Upstream version:\*\* 1\.0\.0'
        }

        It 'with -Force -CheckOnly at the same version reports no update available' {
            $fixture = Join-Path $script:FixtureDir 'full.md'
            Set-Content -LiteralPath $fixture -Value "# Title`n`n**Version:** v9.9.9`n`nPreamble marker text.`n`n$($script:FixtureBody)`n" -Encoding utf8NoBOM -NoNewline
            $null = & $script:UpdateScript -SourceFile $fixture -RepoRoot $script:Repo

            $summary = & $script:UpdateScript -SourceFile $fixture -RepoRoot $script:Repo -Force -CheckOnly

            $summary.Status | Should -Be 'CheckOnly'
            $summary.UpdateAvailable | Should -BeFalse
            $summary.FilesWritten | Should -Be 0
        }
    }

    Context 'failure modes' {

        It 'throws on an unmapped upstream section heading' {
            $fixture = Join-Path $script:FixtureDir 'unmapped.md'
            Set-Content -LiteralPath $fixture -Value "# T`n`n**Version:** v9.9.9`n`n$($script:FixtureBody)`n`n## Mystery section`nmystery content`n" -Encoding utf8NoBOM -NoNewline

            { & $script:UpdateScript -SourceFile $fixture -RepoRoot $script:Repo } | Should -Throw 'Unmapped upstream section*'
        }

        It 'throws when an expected section key is missing from the source' {
            $partial = ($script:FixtureBody -split "`n`n" | Where-Object { $_ -notmatch '^## 5\. ' }) -join "`n`n"
            $fixture = Join-Path $script:FixtureDir 'missing.md'
            Set-Content -LiteralPath $fixture -Value "# T`n`n**Version:** v9.9.9`n`n$partial`n" -Encoding utf8NoBOM -NoNewline

            { & $script:UpdateScript -SourceFile $fixture -RepoRoot $script:Repo } | Should -Throw "Expected upstream section key '5' is missing*"
        }

        It 'throws on an empty upstream document' {
            $fixture = Join-Path $script:FixtureDir 'empty.md'
            Set-Content -LiteralPath $fixture -Value '' -Encoding utf8NoBOM -NoNewline

            { & $script:UpdateScript -SourceFile $fixture -RepoRoot $script:Repo } | Should -Throw 'Upstream document is empty*'
        }

        It 'throws when the upstream version line cannot be parsed' {
            $fixture = Join-Path $script:FixtureDir 'noversion.md'
            Set-Content -LiteralPath $fixture -Value "# T`n`nno version line here`n`n$($script:FixtureBody)`n" -Encoding utf8NoBOM -NoNewline

            { & $script:UpdateScript -SourceFile $fixture -RepoRoot $script:Repo } | Should -Throw 'Could not parse the upstream version*'
        }

        It 'throws when RepoRoot does not exist' {
            $fixture = Join-Path $script:FixtureDir 'full.md'
            Set-Content -LiteralPath $fixture -Value "# T`n`n**Version:** v9.9.9`n`n$($script:FixtureBody)`n" -Encoding utf8NoBOM -NoNewline

            { & $script:UpdateScript -SourceFile $fixture -RepoRoot '/nonexistent/psestd-root' } | Should -Throw 'RepoRoot not found*'
        }

        It 'warns but proceeds when the index is missing' {
            Remove-Item -LiteralPath $script:IndexPath -Force
            $fixture = Join-Path $script:FixtureDir 'full.md'
            Set-Content -LiteralPath $fixture -Value "# Title`n`n**Version:** v9.9.9`n`nPreamble marker text.`n`n$($script:FixtureBody)`n" -Encoding utf8NoBOM -NoNewline

            $output = & $script:UpdateScript -SourceFile $fixture -RepoRoot $script:Repo 3>&1

            ($output | Out-String) | Should -Match 'Index not found'
            $summary = $output | Where-Object { $_.PSTypeNames -contains 'PSEStandard.RefreshSummary' }
            $summary.Status | Should -Be 'Refreshed'
            $summary.IndexUpdated | Should -BeFalse
            $summary.FilesWritten | Should -Be 11
        }
    }

    Context 'fence-aware splitting' {

        It 'does not treat a fenced ## line as a section boundary' {
            $summary = & $script:UpdateScript -SourceFile $script:FencedFixture -RepoRoot $script:Repo

            $summary.Status | Should -Be 'Refreshed'
            $topic = Get-Content -LiteralPath (Join-Path $script:Repo '.agents/rules/powershell/01-function-authoring.md') -Raw
            $topic | Should -Match '## not a heading \(inside a fence\)'
        }
    }
}

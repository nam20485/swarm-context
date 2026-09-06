#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Repository validation script (build, scan, test).

.DESCRIPTION
    Mirrors the CI/CD pipeline exactly. Run locally before committing.
    See .agents/rules/validation.md for the policy this implements.

.PARAMETER Step
    Which step(s) to run: build, scan, test, or all (default).

.PARAMETER CoverageThreshold
    Minimum code coverage percentage (default 85).

.PARAMETER SkipHtml
    Skip HTML coverage report generation.

.EXAMPLE
    ./validation.ps1
    ./validation.ps1 -Step test
    ./validation.ps1 -CoverageThreshold 90 -SkipHtml
#>
[CmdletBinding()]
param(
    [ValidateSet('build', 'scan', 'test', 'all')]
    [string]$Step = 'all',

    [int]$CoverageThreshold = 85,

    [switch]$SkipHtml
)

$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot

$dotnetToolsPath = Join-Path $HOME '.dotnet' 'tools'
if (($env:PATH -notlike "*$dotnetToolsPath*") -and (Test-Path $dotnetToolsPath)) {
    $env:PATH = "$dotnetToolsPath$([IO.Path]::PathSeparator)$env:PATH"
}

function Install-RequiredModule {
    param([string]$Name, [version]$MinVersion)
    $mod = Get-Module -ListAvailable $Name | Where-Object { $_.Version -ge $MinVersion } | Select-Object -First 1
    if (-not $mod) {
        Write-Host "Installing $Name (>= $MinVersion)..." -ForegroundColor Cyan
        Install-Module $Name -MinimumVersion $MinVersion -Force -Scope CurrentUser -AcceptLicense -AllowClobber
    }
}

function Test-CommandAvailable {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Step-Build {
    Write-Host "`n=== BUILD ===" -ForegroundColor Cyan

    if (-not (Test-CommandAvailable 'markdownlint-cli2')) {
        throw "markdownlint-cli2 not found. Install: npm install -g markdownlint-cli2"
    }

    Write-Host "Running markdownlint..." -ForegroundColor Gray
    & markdownlint-cli2
    if ($LASTEXITCODE -ne 0) { throw "markdownlint failed with exit code $LASTEXITCODE" }

    Write-Host "Validating relative Markdown links..." -ForegroundColor Gray
    $linkErrors = @()
    $mdFiles = @('README.md', 'AGENTS.md')
    foreach ($file in $mdFiles) {
        $fullPath = Join-Path $repoRoot $file
        if (-not (Test-Path $fullPath)) { continue }
        $content = Get-Content $fullPath -Raw
        $fileDir = Split-Path $fullPath -Parent
        $linkMatches = [regex]::Matches($content, '\[([^\]]*)\]\(([^)]+)\)')
        foreach ($m in $linkMatches) {
            $linkPath = $m.Groups[2].Value
            if ($linkPath -match '^(https?|mailto):') { continue }
            if ($linkPath -match '^#') { continue }
            $filePath = $linkPath -replace '#.*$', ''
            if ([string]::IsNullOrWhiteSpace($filePath)) { continue }
            $resolved = (Resolve-Path (Join-Path $fileDir $filePath) -ErrorAction SilentlyContinue)
            if (-not $resolved) {
                $linkErrors += "$file -> $linkPath"
            }
        }
    }
    if ($linkErrors.Count -gt 0) {
        throw "Broken relative links found:`n$($linkErrors -join "`n")"
    }

    Write-Host "Build passed." -ForegroundColor Green
}

function Step-Scan {
    Write-Host "`n=== SCAN ===" -ForegroundColor Cyan

    Install-RequiredModule -Name 'PSScriptAnalyzer' -MinVersion '1.20.0'

    $scanDirs = @(
        (Join-Path $repoRoot '.agents/skills/gh-issue-tracking-init/scripts'),
        (Join-Path $repoRoot '.agents/skills/update-powershell-standard/scripts'),
        (Join-Path $repoRoot 'scripts')
    )

    Write-Host "Running PSScriptAnalyzer (Error severity)..." -ForegroundColor Gray
    $errors = @()
    foreach ($dir in $scanDirs) {
        if (Test-Path $dir) {
            $errors += @(Invoke-ScriptAnalyzer -Path $dir -Recurse -Severity Error -ErrorAction SilentlyContinue)
        }
    }
    if ($errors.Count -gt 0) {
        $msg = ($errors | ForEach-Object { "  $($_.ScriptName):$($_.Line) $($_.Message)" }) -join "`n"
        throw "PSScriptAnalyzer found $($errors.Count) error(s):`n$msg"
    }

    $warnings = @()
    foreach ($dir in $scanDirs) {
        if (Test-Path $dir) {
            $warnings += @(Invoke-ScriptAnalyzer -Path $dir -Recurse -Severity Warning -ErrorAction SilentlyContinue)
        }
    }
    if ($warnings.Count -gt 0) {
        Write-Host "PSScriptAnalyzer: $($warnings.Count) warning(s) (non-blocking)" -ForegroundColor Yellow
    }

    if (-not (Test-CommandAvailable 'gitleaks')) {
        throw "gitleaks not found. Install: https://github.com/gitleaks/gitleaks/releases"
    }
    Write-Host "Running gitleaks..." -ForegroundColor Gray
    & gitleaks detect --source $repoRoot --config (Join-Path $repoRoot '.gitleaks.toml') --no-banner --redact
    if ($LASTEXITCODE -ne 0) { throw "gitleaks found leaks (exit code $LASTEXITCODE)" }

    Write-Host "Scan passed." -ForegroundColor Green
}

function Step-Test {
    Write-Host "`n=== TEST ===" -ForegroundColor Cyan

    Install-RequiredModule -Name 'Pester' -MinVersion '5.0.0'

    $testPaths = @(
        (Join-Path $repoRoot '.agents/skills/gh-issue-tracking-init/scripts/tests'),
        (Join-Path $repoRoot '.agents/skills/update-powershell-standard/scripts/tests'),
        (Join-Path $repoRoot '.agents/skills/swarm/scripts/tests')
    )
    $coveragePaths = @(
        (Join-Path $repoRoot '.agents/skills/gh-issue-tracking-init/scripts'),
        (Join-Path $repoRoot '.agents/skills/update-powershell-standard/scripts'),
        (Join-Path $repoRoot '.agents/skills/swarm/scripts')
    )
    $coverageFile = Join-Path $repoRoot 'coverage.xml'

    $cfg = New-PesterConfiguration
    $cfg.Run.Path = $testPaths
    $cfg.CodeCoverage.Enabled = $true
    $cfg.CodeCoverage.Path = $coveragePaths
    $cfg.CodeCoverage.OutputFormat = 'JaCoCo'
    $cfg.CodeCoverage.OutputPath = $coverageFile
    $cfg.Output.Verbosity = 'Minimal'
    $cfg.Run.PassThru = $true

    Write-Host "Running Pester tests..." -ForegroundColor Gray
    $result = Invoke-Pester -Configuration $cfg

    if ($result.FailedCount -gt 0) {
        throw "Pester: $($result.FailedCount) test(s) failed (out of $($result.TotalCount))"
    }

    Write-Host "Pester: $($result.PassedCount)/$($result.TotalCount) tests passed" -ForegroundColor Green

    $coveragePercent = [math]::Round($result.CodeCoverage.CoveragePercent, 2)
    $executed = $result.CodeCoverage.CommandsExecutedCount
    $analyzed = $result.CodeCoverage.CommandsAnalyzedCount
    $color = if ($coveragePercent -ge $CoverageThreshold) { 'Green' } else { 'Red' }
    Write-Host "Coverage: $coveragePercent% ($executed/$analyzed commands)" -ForegroundColor $color

    if ($coveragePercent -lt $CoverageThreshold) {
        $needed = [math]::Ceiling($CoverageThreshold * $analyzed / 100)
        throw "Coverage $coveragePercent% is below threshold $CoverageThreshold% (need $needed executed, have $executed)"
    }

    if (-not $SkipHtml) {
        Write-Host "Generating HTML coverage report..." -ForegroundColor Gray
        $rgInstalled = (dotnet tool list -g 2>$null) -match 'dotnet-reportgenerator-globaltool'
        if (-not $rgInstalled) {
            Write-Host "Installing ReportGenerator..." -ForegroundColor Gray
            dotnet tool install --global dotnet-reportgenerator-globaltool --version 5.5.10
            if ($LASTEXITCODE -ne 0) { throw "Failed to install ReportGenerator" }
        }

        $htmlDir = Join-Path $repoRoot 'coverage-html'
        & reportgenerator "-reports:$coverageFile" "-targetdir:$htmlDir" "-reporttypes:Html"
        if ($LASTEXITCODE -ne 0) { throw "ReportGenerator failed with exit code $LASTEXITCODE" }
        Write-Host "HTML coverage report generated at coverage-html/" -ForegroundColor Green
    }

    Write-Host "Test passed." -ForegroundColor Green
}

Set-Location $repoRoot

switch ($Step) {
    'build' { Step-Build }
    'scan'  { Step-Scan }
    'test'  { Step-Test }
    'all'   { Step-Build; Step-Scan; Step-Test }
}

Write-Host "`nAll validation steps passed." -ForegroundColor Green

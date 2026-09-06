#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Scan rendered GitHub issue body files for secrets before they are posted.

.DESCRIPTION
    This is a DryRun assertion for the gh-issue-tracking-init skill. After the
    agent renders issue bodies (from the plan-doc content) but BEFORE any
    `gh issue create` call, this script scans the rendered body files for
    credential-shaped content and THROWS on confident detection.

    Behaviour: throw-and-halt. No automatic redaction. Secrets posted to public
    GitHub issues are a one-way door (scraped within seconds, cached by archives
    even after deletion). The cost of a false positive (halting on something that
    wasn't a secret) is a re-run; the cost of a false negative is catastrophic.

    Three detection tiers:
      1. Token patterns  — format-specific prefixes (AWS, GitHub, OpenAI, Stripe,
                            Google, Slack, GitLab, JWT, Bearer, private keys).
                            NEVER allowlisted — if the format matches, it's flagged.
      2. Structural       — connection strings with embedded user:pass@host,
                            hardcoded password assignments. Value-level allowlist.
      3. Credential-keyed — key name matches a credential word (password, token,
                            secret, api_key, access_key, AccountKey, …) and the
                            value is not a placeholder. Value-level allowlist.

    The placeholder allowlist (${VAR}, changeme, redacted, <YOUR_API_KEY>,
    example.com, …) is applied at the VALUE level, never at the line level.
    A placeholder substring on the same line as a real secret does NOT suppress
    detection of the secret.

.PARAMETER BodyFiles
    One or more paths to rendered issue-body files to scan.

.PARAMETER DryRun
    Report findings to stdout without throwing. For standalone diagnostic use.
    When called from the skill's DryRun/Apply pass, do NOT pass this flag —
    the script must throw to halt the run before `gh issue create`.

.EXAMPLE
    & "$Skill/assert-no-secrets.ps1" -BodyFiles $bodies.BodyFile

.EXAMPLE
    & "$Skill/assert-no-secrets.ps1" -BodyFiles ./bodies/*.md -DryRun

.NOTES
    Requires: PowerShell 7+. No gh CLI dependency — this is a pure file scanner.
    Self-contained: no dot-source of common.ps1 (no auth needed).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string[]]$BodyFiles,

    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Value-level allowlist ────────────────────────────────────────────────────
# Applied to the extracted credential VALUE (not the entire line).
# Plan docs legitimately contain placeholders like ${POSTGRES_PASSWORD},
# changeme, <YOUR_API_KEY>, …. These are NOT secrets and must not trigger.

function Test-AllowlistedCredentialValue {
    <#.SYNOPSIS Return true if a credential value is a safe placeholder.#>
    param([string]$Value)
    if ($Value -match '^\$\{?[A-Za-z_][A-Za-z0-9_-]*\}?$') { return $true }
    if ($Value -eq '…' -or $Value -eq '...') { return $true }
    if ($Value -match 'FAKE-.+-FOR-TESTING') { return $true }
    if ($Value -in 'secret', 'changeme', 'placeholder', 'redacted', 'REDACTED',
                      'test', 'example', 'demo', 'dummy', 'sample') { return $true }
    if ($Value -match '^paste-') { return $true }
    if ($Value -match '^<YOUR_') { return $true }
    if ($Value -match 'your-.*-key') { return $true }
    if ($Value -match 'example\.(com|org|net)') { return $true }
    if ($Value -match '^(?i)(true|false|yes|no|on|off|none|null|0|1)$') { return $true }
    return $false
}

# ── Pattern definitions ──────────────────────────────────────────────────────

# Tier 1: Format-specific token patterns (high confidence — specific prefix/format).
# These are NEVER allowlisted: if the format matches, the token is flagged regardless
# of what else appears on the line.
$tokenPatterns = @(
    @{ Cat = 'API_KEY'; Pat = 'AKIA[0-9A-Z]{16}';              Desc = 'AWS access key id' }
    @{ Cat = 'API_KEY'; Pat = 'ASIA[0-9A-Z]{16}';              Desc = 'AWS temporary access key id' }
    @{ Cat = 'API_KEY'; Pat = 'sk-or-v1-[a-zA-Z0-9_-]{10,}';   Desc = 'OpenRouter/OpenAI-style key' }
    @{ Cat = 'API_KEY'; Pat = 'sk-proj-[a-zA-Z0-9_-]{10,}';    Desc = 'OpenAI project key' }
    @{ Cat = 'API_KEY'; Pat = '(?<![a-zA-Z0-9])sk-[a-zA-Z0-9]{20,}(?![a-zA-Z0-9])'; Desc = 'Secret key (sk- prefix)' }
    @{ Cat = 'API_KEY'; Pat = 'sk_live_[a-zA-Z0-9]{20,}';      Desc = 'Stripe live secret key' }
    @{ Cat = 'API_KEY'; Pat = 'rk_live_[a-zA-Z0-9]{20,}';      Desc = 'Stripe live restricted key' }
    @{ Cat = 'API_KEY'; Pat = 'sk_test_[a-zA-Z0-9]{20,}';      Desc = 'Stripe test secret key' }
    @{ Cat = 'API_KEY'; Pat = 'rk_test_[a-zA-Z0-9]{20,}';      Desc = 'Stripe test restricted key' }
    @{ Cat = 'API_KEY'; Pat = 'AIza[0-9A-Za-z_-]{35}';         Desc = 'Google Cloud API key' }
    @{ Cat = 'TOKEN';   Pat = 'ghp_[a-zA-Z0-9]{20,}';          Desc = 'GitHub personal access token' }
    @{ Cat = 'TOKEN';   Pat = 'ghs_[a-zA-Z0-9]{20,}';          Desc = 'GitHub secret/token' }
    @{ Cat = 'TOKEN';   Pat = 'gho_[a-zA-Z0-9]{20,}';          Desc = 'GitHub OAuth token' }
    @{ Cat = 'TOKEN';   Pat = 'ghu_[a-zA-Z0-9]{20,}';          Desc = 'GitHub user token' }
    @{ Cat = 'TOKEN';   Pat = 'ghr_[a-zA-Z0-9]{20,}';          Desc = 'GitHub refresh token' }
    @{ Cat = 'TOKEN';   Pat = 'github_pat_[a-zA-Z0-9_]{20,}';  Desc = 'GitHub fine-grained PAT' }
    @{ Cat = 'TOKEN';   Pat = 'glpat-[a-zA-Z0-9_-]{10,}';      Desc = 'GitLab personal access token' }
    @{ Cat = 'TOKEN';   Pat = 'xox[baprs]-[a-zA-Z0-9-]{10,}';  Desc = 'Slack token' }
    @{ Cat = 'TOKEN';   Pat = 'Bearer\s+[a-zA-Z0-9\-\._~+/]{20,}'; Desc = 'Bearer token' }
    @{ Cat = 'TOKEN';   Pat = 'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}'; Desc = 'Possible JWT' }
    @{ Cat = 'SECRET';  Pat = '-----BEGIN (RSA |OPENSSH |EC |DSA |PGP )?PRIVATE KEY( BLOCK)?-----'; Desc = 'Private key block' }
)

# ── Scan ─────────────────────────────────────────────────────────────────────

$findings = [System.Collections.Generic.List[pscustomobject]]::new()

function Add-Finding {
    param([string]$File, [int]$LineNo, [string]$Cat, [string]$Desc, [string]$Content)
    $findings.Add([pscustomobject]@{
        File = $File; Line = $LineNo; Category = $Cat
        Description = $Desc; Content = $Content
    })
}

foreach ($file in $BodyFiles) {
    if (-not (Test-Path -LiteralPath $file)) {
        Write-Warning "assert-no-secrets: body file not found, skipping: $file"
        continue
    }
    $lines = @(Get-Content -LiteralPath $file)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line   = $lines[$i]
        $lineNo = $i + 1

        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        # NO line-level allowlist short-circuit. Each pattern handles its own
        # value-level allowlist. This prevents a placeholder substring on the
        # same line from suppressing detection of a real secret.

        # ── Tier 1: Token patterns (never allowlisted) ──
        foreach ($p in $tokenPatterns) {
            if ($line -match $p.Pat) {
                Add-Finding -File $file -LineNo $lineNo -Cat $p.Cat -Desc $p.Desc -Content $line
            }
        }

        # ── Tier 2a: Connection string with embedded credentials (user:pass@host) ──
        # Capture group 3 = password. Allowlist-check the password value.
        if ($line -match '([a-zA-Z][a-zA-Z0-9+.-]*)://([^:@\s]+):([^@\s]+)@') {
            $password = $Matches[3]
            if (-not (Test-AllowlistedCredentialValue -Value $password)) {
                Add-Finding -File $file -LineNo $lineNo -Cat 'SECRET' `
                    -Desc 'Credentials embedded in connection string (user:pass@host)' -Content $line
            }
        }

        # ── Tier 2b: Hardcoded password assignment (quoted value ≥4 chars) ──
        if ($line -match "(?<![a-zA-Z0-9_])(password|passwd|pwd)\s*[:=]\s*[`"`'']([^`"`'']{4,})[`"`'']") {
            $val = $Matches[2]
            if (-not (Test-AllowlistedCredentialValue -Value $val)) {
                Add-Finding -File $file -LineNo $lineNo -Cat 'PASSWORD' `
                    -Desc 'Hardcoded password assignment' -Content $line
            }
        }

        # ── Tier 3: Credential-keyed assignment (ANYWHERE on the line) ──
        # Two-step: (1) find ALL key=value pairs on the line via [regex]::Matches
        # (not just the first), catching embedded assignments in connection strings
        # (Server=db;Password=S3cr3t;...), after ;, etc.; (2) check if the full
        # key name CONTAINS a credential word (substring match handles compound
        # names like client_secret, access_token, AccountKey). Value class excludes
        # whitespace, quotes, and ; (SQL Server delimiter) but includes # (Fix 5).
        $credWordRegex = '(?i)(password|passwd|pwd|passphrase|token|secret|api[_-]?key|apikey|access[_-]?key|account[_-]?key|storage[_-]?key|auth[_-]?token|credential|private[_-]?key)'
        $assignRegex   = [regex]'(?<![a-zA-Z0-9_])([A-Za-z][A-Za-z0-9_-]*)\s*[:=]\s*[''""]?([^''""\s;]+)'
        foreach ($m in $assignRegex.Matches($line)) {
            $key = $m.Groups[1].Value
            $val = $m.Groups[2].Value
            if ($key -match $credWordRegex -and
                -not [string]::IsNullOrWhiteSpace($val) -and
                -not (Test-AllowlistedCredentialValue -Value $val)) {
                Add-Finding -File $file -LineNo $lineNo -Cat 'SECRET' `
                    -Desc "Credential assignment (key=$key)" -Content $line
            }
        }
    }
}

# ── Report ───────────────────────────────────────────────────────────────────

if ($findings.Count -gt 0) {
    Write-Host ''
    Write-Host '======================================================================'
    Write-Host "  SECRET SCAN: $($findings.Count) potential secret(s) detected"
    Write-Host '  These MUST be redacted in the plan doc before creating GitHub issues.'
    Write-Host '======================================================================'
    Write-Host ''
    foreach ($f in $findings) {
        Write-Host "[$($f.Category)] $($f.File):$($f.Line)"
        Write-Host "  rule: $($f.Description)"
        Write-Host "  line: $($f.Content)"
        Write-Host ''
    }
    if (-not $DryRun) {
        $f0 = $findings[0]
        $first = "First: [$($f0.Category)] $($f0.File):$($f0.Line) - $($f0.Description)"
        throw ("Secret scan halted: $($findings.Count) potential secret(s) detected. " +
               "$first. See full report above. Redact in the plan doc and re-run. " +
               'Pass -DryRun to this script for report-only mode.')
    }
} else {
    Write-Host "assert-no-secrets: no sensitive content detected in $($BodyFiles.Count) body file(s)."
}

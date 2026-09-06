#!/usr/bin/env pwsh
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
    Pester tests for assert-no-secrets.ps1 — the pre-post secret scanner for
    rendered GitHub issue bodies.

    Covers: each token-pattern category, structural patterns, credential-keyed
    assignments, the placeholder allowlist, throw-vs-DryRun behaviour, and
    missing-file resilience.

    Run:  Invoke-Pester -Path .agents/skills/gh-issue-tracking-init/scripts/tests -Output Detailed
#>

BeforeAll {
    $script:Script = Join-Path (Split-Path -Parent $PSScriptRoot) 'assert-no-secrets.ps1'

    function Invoke-ScanResult {
        <#.SYNOPSIS Run assert-no-secrets against temp content, capture all output + throw status.#>
        param([string]$Content, [switch]$DryRun)
        $tmp = [System.IO.Path]::GetTempFileName()
        try {
            Set-Content -LiteralPath $tmp -Value $Content -NoNewline
            $output = & $script:Script -BodyFiles $tmp -DryRun:$DryRun *>&1
            return @{ Output = ($output | Out-String); Threw = $false }
        } catch {
            return @{ Output = ($_.Exception.Message); Threw = $true }
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'assert-no-secrets.ps1' {

    Context 'Clean content with placeholders (must NOT trigger)' {
        It 'passes a body with only ${VAR} interpolation' {
            $r = Invoke-ScanResult -Content 'Password=${POSTGRES_PASSWORD}' -DryRun
            $r.Threw | Should -Be $false
            $r.Output | Should -Match 'no sensitive content'
        }
        It 'passes a body with <YOUR_API_KEY> placeholder' {
            $r = Invoke-ScanResult -Content 'api_key=<YOUR_API_KEY>' -DryRun
            $r.Threw | Should -Be $false
            $r.Output | Should -Match 'no sensitive content'
        }
        It 'passes a body with changeme / redacted / placeholder' {
            $r = Invoke-ScanResult -Content "password=`"changeme`"`nsecret=`"redacted`"`ntoken=`"placeholder`"" -DryRun
            $r.Threw | Should -Be $false
        }
        It 'passes a body with ellipsis placeholder' {
            $r = Invoke-ScanResult -Content 'api_key = "…"' -DryRun
            $r.Threw | Should -Be $false
        }
        It 'passes a body with example.com connection strings' {
            $r = Invoke-ScanResult -Content 'Server=db.example.com;Password=test' -DryRun
            $r.Threw | Should -Be $false
            $r.Output | Should -Match 'no sensitive content'
        }
        It 'passes a body with common doc placeholder values (test/example/demo)' {
            $r = Invoke-ScanResult -Content "password=`"test`"`nsecret=`"example`"`ntoken=`"demo`"" -DryRun
            $r.Output | Should -Match 'no sensitive content'
        }
    }

    Context 'Regression: # -prefixed credential values (bypass fix)' {
        It 'detects password starting with #' {
            $r = Invoke-ScanResult -Content 'password=#realsecret12345' -DryRun
            $r.Output | Should -Match 'Credential|password'
        }
        It 'detects token starting with #' {
            $r = Invoke-ScanResult -Content 'token=#myrealtokenvalue12345' -DryRun
            $r.Output | Should -Match 'Credential'
        }
    }

    Context 'Regression: allowlist bypass (CRITICAL — placeholder must NOT suppress real secrets)' {
        It 'detects AWS key even when ${VAR} appears on same line' {
            $r = Invoke-ScanResult -Content ('api_key = "' + 'AK' + 'IAIOSFODNN7REALKEY12" # uses ${VAR}') -DryRun
            $r.Output | Should -Match 'AWS access key id'
        }
        It 'detects GitHub token even when $PATH appears on same line' {
            $r = Invoke-ScanResult -Content ('token = "' + 'gh' + 'p_1234567890abcdefghijklmnopqrstuv" # cf. $PATH') -DryRun
            $r.Output | Should -Match 'GitHub'
        }
        It 'detects password even when example.com appears on same line' {
            $r = Invoke-ScanResult -Content 'password = "S3cr3t" # see db.example.com' -DryRun
            $r.Output | Should -Match 'password|Credential'
        }
        It 'detects secret even when changeme appears on same line' {
            $r = Invoke-ScanResult -Content 'secret = "realvalue12345" # changeme before prod' -DryRun
            $r.Output | Should -Match 'Credential'
        }
    }

    Context 'Token pattern detection' {
        It 'detects AWS access key id (AKIA...)' {
            $r = Invoke-ScanResult -Content ('key = ' + 'AK' + 'IAIOSFODNN7EXAMPLE') -DryRun
            $r.Output | Should -Match 'AWS access key id'
        }
        It 'detects GitHub personal access token (ghp_...)' {
            $r = Invoke-ScanResult -Content ('token = ' + 'gh' + 'p_1234567890abcdefghijklmnopqrstuvwxyz') -DryRun
            $r.Output | Should -Match 'GitHub personal access token'
        }
        It 'detects OpenAI project key (sk-proj-...)' {
            $r = Invoke-ScanResult -Content ('key = ' + 'sk-pr' + 'oj-abcdef1234567890ABCDEFGHIJ') -DryRun
            $r.Output | Should -Match 'OpenAI project key'
        }
        It 'detects Stripe live secret key (sk_live_...)' {
            $r = Invoke-ScanResult -Content ('key = ' + 'sk_l' + 'ive_51AbCdEf1234567890GhIjKl') -DryRun
            $r.Output | Should -Match 'Stripe'
        }
        It 'detects Google Cloud API key (AIza...)' {
            $r = Invoke-ScanResult -Content ('key = ' + 'AI' + 'zaSyD-abcdefghijklmnopqrstuvwxyz1234567') -DryRun
            $r.Output | Should -Match 'Google'
        }
        It 'detects GitLab token (glpat-...)' {
            $r = Invoke-ScanResult -Content ('token = ' + 'glp' + 'at-1234567890abcdef') -DryRun
            $r.Output | Should -Match 'GitLab'
        }
        It 'detects Slack token (xox...)' {
            $r = Invoke-ScanResult -Content ('token = ' + 'xo' + 'xb-1234567890-abcdef') -DryRun
            $r.Output | Should -Match 'Slack'
        }
        It 'detects Bearer token' {
            $r = Invoke-ScanResult -Content ('Authorization: Bearer ' + 'dGhpcy' + 'BpcyBhIHZlcnkgbG9uZyB0b2tlbiE=') -DryRun
            $r.Output | Should -Match 'Bearer token'
        }
        It 'detects JWT (eyJ...)' {
            $r = Invoke-ScanResult -Content ('jwt = ' + 'ey' + 'JhbGciOiJIUzI1.eyJzdWIiOiIxMjM0.SflKxwRJSMeKKF2QT4f') -DryRun
            $r.Output | Should -Match 'JWT'
        }
        It 'detects private key block (RSA)' {
            $r = Invoke-ScanResult -Content '-----BEGIN RSA PRIVATE KEY-----' -DryRun
            $r.Output | Should -Match 'Private key block'
        }
        It 'detects PGP private key block' {
            $r = Invoke-ScanResult -Content '-----BEGIN PGP PRIVATE KEY BLOCK-----' -DryRun
            $r.Output | Should -Match 'Private key block'
        }
    }

    Context 'Structural pattern detection' {
        It 'detects credentials in connection string (user:pass@host)' {
            $r = Invoke-ScanResult -Content 'DATABASE_URL = "postgresql://admin:S3cr3tPass@db.internal:5432/mydb"' -DryRun
            $r.Output | Should -Match 'connection string'
        }
        It 'detects password with / in connection string' {
            $r = Invoke-ScanResult -Content 'url = "redis://admin:Aa1/bCd2@cache.internal:6379"' -DryRun
            $r.Output | Should -Match 'connection string'
        }
        It 'detects hardcoded password assignment (quoted)' {
            $r = Invoke-ScanResult -Content 'password = "MyRealPassword123"' -DryRun
            $r.Output | Should -Match 'password'
        }
        It 'detects embedded password in SQL Server connection string' {
            $r = Invoke-ScanResult -Content 'Server=db.internal;User Id=admin;Password=S3cr3tDbP@ss;Database=mydb' -DryRun
            $r.Output | Should -Match 'Credential|password'
        }
    }

    Context 'Credential-keyed assignment detection' {
        It 'detects api_key = "realvalue" (quoted)' {
            $r = Invoke-ScanResult -Content 'api_key = "real_secret_value_12345"' -DryRun
            $r.Output | Should -Match 'Credential assignment'
        }
        It 'detects secret: realvalue (unquoted)' {
            $r = Invoke-ScanResult -Content 'secret: real_secret_value_12345' -DryRun
            $r.Output | Should -Match 'Credential assignment'
        }
        It 'detects client_secret = "realvalue"' {
            $r = Invoke-ScanResult -Content 'client_secret = "abc123def456ghi789"' -DryRun
            $r.Output | Should -Match 'client_secret'
        }
        It 'detects access_key = "realvalue"' {
            $r = Invoke-ScanResult -Content 'access_key = "AKIA-real-access-key-value"' -DryRun
            $r.Output | Should -Match 'Credential assignment'
        }
        It 'detects AccountKey in Azure connection string' {
            $r = Invoke-ScanResult -Content 'DefaultEndpointsProtocol=https;AccountName=mystorage;AccountKey=aBV3ryLongBase64Value==;EndpointSuffix=core.windows.net' -DryRun
            $r.Output | Should -Match 'Credential assignment'
        }
        It 'does NOT flag api_key = ${API_KEY}' {
            $r = Invoke-ScanResult -Content 'api_key = ${API_KEY}' -DryRun
            $r.Output | Should -Match 'no sensitive content'
        }
    }

    Context 'Throw vs DryRun behaviour' {
        It 'THROWS without -DryRun when secrets are found' {
            $r = Invoke-ScanResult -Content ('gh' + 'p_1234567890abcdefghijklmnopqrstuvwxyz')
            $r.Threw | Should -Be $true
            $r.Output | Should -Match 'Secret scan halted'
        }
        It 'does NOT throw with -DryRun when secrets are found' {
            $r = Invoke-ScanResult -Content ('gh' + 'p_1234567890abcdefghijklmnopqrstuvwxyz') -DryRun
            $r.Threw | Should -Be $false
            $r.Output | Should -Match 'potential secret'
        }
        It 'does NOT throw when no secrets are found (no DryRun)' {
            $r = Invoke-ScanResult -Content 'api_key = ${API_KEY}'
            $r.Threw | Should -Be $false
        }
    }

    Context 'Edge cases' {
        It 'reports a warning and continues for a missing file' {
            $tmp = [System.IO.Path]::GetTempFileName()
            try {
                Set-Content -LiteralPath $tmp -Value 'api_key = ${OK}' -NoNewline
                $output = & $script:Script -BodyFiles $tmp, '/nonexistent/file.md' -DryRun *>&1 | Out-String
                $output | Should -Match 'not found, skipping'
            } finally {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            }
        }
        It 'handles empty file gracefully' {
            $tmp = [System.IO.Path]::GetTempFileName()
            try {
                Set-Content -LiteralPath $tmp -Value '' -NoNewline
                $output = & $script:Script -BodyFiles $tmp -DryRun *>&1 | Out-String
                $output | Should -Match 'no sensitive content'
            } finally {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            }
        }
        It 'rejects empty -BodyFiles array' {
            { & $script:Script -BodyFiles @() } | Should -Throw
        }
    }
}

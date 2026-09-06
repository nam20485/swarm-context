# Agent Readiness Gap Analysis

**Repository:** `intel-agency/agent-context`
**Report ID:** `5a0b1d58`
**Commit:** `e4853e8` (branch: `development`)
**Date:** 2026-07-24

## Scoring Methodology

Each gap is rated on two dimensions:

- **Value (1-5):** Impact on agent readiness level if closed. 5 = directly enables agent effectiveness; 1 = marginal for this repo type.
- **Difficulty (1-5):** Effort, risk, and complexity to implement. 1 = config file; 5 = tool doesn't exist for the platform.
- **ROI Score:** Value minus Difficulty. Higher = more bang for the buck.

Gaps are sorted by ROI score (descending) and grouped into three tiers:

| Tier | ROI Score | Meaning |
|------|-----------|---------|
| Quick Wins | >= 2 | High value, low effort. Do these first. |
| Medium Effort | 0 to 1 | Worthwhile but requires moderate work. |
| Strategic Investments | < 0 | High difficulty or low value for this repo. Plan carefully or defer. |

**Current score:** 29/65 non-skipped criteria passing (44.6%) - Level 3.

---

## Tier 1: Quick Wins (ROI >= 2)

### 1. Pre-commit Hooks

| Field | Value |
|-------|-------|
| Criterion | `pre_commit_hooks` |
| Current | 0/1 |
| Value | 5 |
| Difficulty | 2 |
| ROI | **3** |
| Solution | Add `.pre-commit-config.yaml` with hooks for markdownlint-cli2, PSScriptAnalyzer, and gitleaks. Reuses tools already configured in `validation.ps1`. Alternatively, add a `scripts/pre-commit.ps1` that calls `./validation.ps1` and install via `git config core.hooksPath scripts/hooks`. |

### 2. DevContainer

| Field | Value |
|-------|-------|
| Criterion | `devcontainer` |
| Current | 0/1 |
| Value | 5 |
| Difficulty | 3 |
| ROI | **2** |
| Solution | Create `.devcontainer/devcontainer.json` with PowerShell 7, gh CLI, markdownlint-cli2, gitleaks, ReportGenerator, and PSScriptAnalyzer. Use the `mcr.microsoft.com/powershell` base image plus a Dockerfile for tool installation. Gives agents a reproducible one-click environment. |

### 3. Single-Command Setup

| Field | Value |
|-------|-------|
| Criterion | `single_command_setup` |
| Current | 0/1 |
| Value | 4 |
| Difficulty | 2 |
| ROI | **2** |
| Solution | Create `scripts/setup.ps1` that installs required tools (pwsh, gh, markdownlint-cli2, gitleaks, ReportGenerator), verifies gh auth, links `docs/environment-variables.md` as `.env.example`, and runs `./validation.ps1`. Document in README as `./scripts/setup.ps1`. |

### 4. Dependency Update Automation

| Field | Value |
|-------|-------|
| Criterion | `dependency_update_automation` |
| Current | 0/1 |
| Value | 4 |
| Difficulty | 2 |
| ROI | **2** |
| Solution | Add `.github/dependabot.yml` with `github-actions` ecosystem (updates pinned action SHAs in `ci.yml`) and `submodules` if applicable. Configure weekly schedule and auto-assign reviewer. |

### 5. Dependencies Pinned

| Field | Value |
|-------|-------|
| Criterion | `deps_pinned` |
| Current | 0/1 |
| Value | 4 |
| Difficulty | 2 |
| ROI | **2** |
| Solution | Pin all PowerShell module versions in `validation.ps1` and CI workflow (e.g., `Pester@5.7.2`, `PSScriptAnalyzer@1.24.0`). Add a `modules.lock.json` or pin in `RequiredModules` of a module manifest. GitHub Actions already use SHA pins. |

### 6. Automated PR Review

| Field | Value |
|-------|-------|
| Criterion | `automated_pr_review` |
| Current | 0/1 |
| Value | 4 |
| Difficulty | 2 |
| ROI | **2** |
| Solution | Install a GitHub App reviewer such as CodeRabbit or Qodo (formerly Codium). Alternatively, add a CI job that runs PSScriptAnalyzer and posts results as a PR comment via `actions/github-script`. |

### 7. Automated Security Review

| Field | Value |
|-------|-------|
| Criterion | `automated_security_review` |
| Current | 0/1 |
| Value | 5 |
| Difficulty | 3 |
| ROI | **2** |
| Solution | Add Semgrep CI job to `.github/workflows/ci.yml` with `semgrep --config=auto`. Semgrep supports PowerShell and YAML. Alternatively, enable GitHub CodeQL analysis with a `codeql.yml` workflow. |

### 8. Log Scrubbing

| Field | Value |
|-------|-------|
| Criterion | `log_scrubbing` |
| Current | 0/1 |
| Value | 4 |
| Difficulty | 2 |
| ROI | **2** |
| Solution | Add a `-RedactPatterns` parameter to `Write-Log` in `common.ps1` that regex-replaces token-like strings (ghp_*, github_pat_*, AKIA*, Bearer tokens) with `[REDACTED]` before writing to log files. Add Pester tests for redaction. |

### 9. Formatter

| Field | Value |
|-------|-------|
| Criterion | `formatter` |
| Current | 0/1 |
| Value | 3 |
| Difficulty | 1 |
| ROI | **2** |
| Solution | Add `.prettierrc` with markdown formatting config. Add PSScriptAnalyzer formatter settings (`PSScriptFormatterSettings`) or use `Invoke-Formatter` in a `scripts/format.ps1` script. Integrate with pre-commit hooks. |

### 10. Naming Consistency

| Field | Value |
|-------|-------|
| Criterion | `naming_consistency` |
| Current | 0/1 |
| Value | 3 |
| Difficulty | 1 |
| ROI | **2** |
| Solution | Document PowerShell naming conventions in `.agents/rules/coding-style.md` (PascalCase for functions, camelCase for variables, approved verbs). Configure PSScriptAnalyzer `PSUseApprovedVerbs` and `PSUseSingularNouns` as Error severity in `validation.ps1`. |

---

## Tier 2: Medium Effort (ROI 0 to 1)

### 11. Duplicate Code Detection

| Field | Value |
|-------|-------|
| Criterion | `duplicate_code_detection` |
| Current | 0/1 |
| Value | 3 |
| Difficulty | 2 |
| ROI | **1** |
| Solution | Add jscpd to CI with `jscpd --pattern "**/*.ps1"` and a threshold (e.g., 3%). jscpd is language-agnostic and works on any text. Add `scripts/check-duplicates.ps1` wrapper. |

### 12. Tech Debt Tracking

| Field | Value |
|-------|-------|
| Criterion | `tech_debt_tracking` |
| Current | 0/1 |
| Value | 3 |
| Difficulty | 2 |
| ROI | **1** |
| Solution | Add `leasot` or a custom `grep -rn "TODO\|FIXME\|HACK\|XXX"` step in `validation.ps1` that reports counts. Track in CI output and fail if count increases beyond a baseline. |

### 13. Flaky Test Detection

| Field | Value |
|-------|-------|
| Criterion | `flaky_test_detection` |
| Current | 0/1 |
| Value | 3 |
| Difficulty | 2 |
| ROI | **1** |
| Solution | Add Pester `-Run.TestPlugin` or run tests 3 times in CI with `for i in 1..3; do pwsh -Command 'Invoke-Pester ...'`. Track failures across runs. Alternatively, add GitHub Actions `retries` to the test step. |

### 14. Service Flow Documented

| Field | Value |
|-------|-------|
| Criterion | `service_flow_documented` |
| Current | 0/1 |
| Value | 3 |
| Difficulty | 2 |
| ROI | **1** |
| Solution | Add `docs/architecture.mmd` or a Mermaid diagram in README showing the flow: template repo -> downstream clone -> AGENTS.md -> .agents/ -> skills -> scripts -> GitHub API. |

### 15. Runbooks Documented

| Field | Value |
|-------|-------|
| Criterion | `runbooks_documented` |
| Current | 0/1 |
| Value | 3 |
| Difficulty | 2 |
| ROI | **1** |
| Solution | Create `docs/runbooks/` with markdown files for common operations: label sync, milestone creation, issue triage, branch protection updates, CI failure diagnosis. |

### 16. Automated Doc Generation

| Field | Value |
|-------|-------|
| Criterion | `automated_doc_generation` |
| Current | 0/1 |
| Value | 3 |
| Difficulty | 2 |
| ROI | **1** |
| Solution | Add `scripts/generate-docs.ps1` that extracts PowerShell comment-based help from all scripts in `scripts/` and `.agents/skills/` and generates `docs/api-reference.md`. Run in CI as a check. |

### 17. Release Notes Automation

| Field | Value |
|-------|-------|
| Criterion | `release_notes_automation` |
| Current | 0/1 |
| Value | 3 |
| Difficulty | 2 |
| ROI | **1** |
| Solution | Add `semantic-release` or `release-please` GitHub Action that generates changelog entries from conventional commit messages. The repo already uses conventional commits (feat:, fix:, docs:, ci:). |

### 18. Min Release Age

| Field | Value |
|-------|-------|
| Criterion | `min_release_age` |
| Current | 0/1 |
| Value | 3 |
| Difficulty | 2 |
| ROI | **1** |
| Solution | Add Renovate config (`renovate.json`) with `minimumReleaseAge: "3 days"` to prevent auto-merging fresh releases. Pairs with `dependency_update_automation`. |

### 19. Large File Detection

| Field | Value |
|-------|-------|
| Criterion | `large_file_detection` |
| Current | 0/1 |
| Value | 2 |
| Difficulty | 1 |
| ROI | **1** |
| Solution | Add a CI step that checks file sizes via `Get-ChildItem -Recurse \| Where-Object Length -gt 100KB` and fails if any tracked file exceeds 100KB. Add `.gitattributes` with Git LFS rules for binary assets if needed. |

### 20. Cyclomatic Complexity

| Field | Value |
|-------|-------|
| Criterion | `cyclomatic_complexity` |
| Current | 0/1 |
| Value | 3 |
| Difficulty | 3 |
| ROI | **0** |
| Solution | Write a custom PSScriptAnalyzer rule or PowerShell script that counts branch points (if, else, switch, foreach, while, catch) per function. Fail CI if any function exceeds threshold (e.g., 15). No off-the-shelf PS complexity tool exists. |

### 21. Dead Code Detection

| Field | Value |
|-------|-------|
| Criterion | `dead_code_detection` |
| Current | 0/1 |
| Value | 3 |
| Difficulty | 3 |
| ROI | **0** |
| Solution | Write a custom AST-based scanner using `System.Management.Automation.Language.Parser` to find public functions never referenced outside their defining file. Alternatively, use `PSAvoidUnusedVariable` at Warning severity and add a custom rule for unused functions. |

### 22. Integration Tests

| Field | Value |
|-------|-------|
| Criterion | `integration_tests_exist` |
| Current | 0/1 |
| Value | 4 |
| Difficulty | 4 |
| ROI | **0** |
| Solution | Add a `tests/integration/` directory with Pester tests that call real gh API against a throwaway test repo. Use `BeforeAll` to create a temp repo, `AfterAll` to delete it. Requires `GITHUB_TOKEN` with repo scope in CI. Mock tests already cover 93.91% of unit logic. |

### 23. Test Isolation

| Field | Value |
|-------|-------|
| Criterion | `test_isolation` |
| Current | 0/1 |
| Value | 3 |
| Difficulty | 3 |
| ROI | **0** |
| Solution | Enable Pester v5 parallel execution with `-Parallelize` and `Run.ScopeIsolation`. This requires refactoring global:gh mocks to be runsafe (use `$mock` scope instead of global function). Add `-RandomizeTests` if available in Pester 5.7+. |

### 24. Release Automation

| Field | Value |
|-------|-------|
| Criterion | `release_automation` |
| Current | 0/1 |
| Value | 3 |
| Difficulty | 3 |
| ROI | **0** |
| Solution | Add a `release.yml` workflow that triggers on tag push, runs `validation.ps1`, creates a GitHub Release with auto-generated notes, and uploads any build artifacts. Pairs with `release_notes_automation`. |

---

## Tier 3: Strategic Investments (ROI < 0)

### 25. Unused Dependencies Detection

| Field | Value |
|-------|-------|
| Criterion | `unused_dependencies_detection` |
| Current | 0/1 |
| Value | 2 |
| Difficulty | 3 |
| ROI | **-1** |
| Solution | No PowerShell-specific unused dependency scanner exists. Could write a custom AST scanner that checks `Import-Module` / `#require` statements against actual cmdlet usage. Low value for this small repo with few dependencies. |

### 26. Metrics Collection

| Field | Value |
|-------|-------|
| Criterion | `metrics_collection` |
| Current | 0/1 |
| Value | 2 |
| Difficulty | 3 |
| ROI | **-1** |
| Solution | Add custom instrumentation to `common.ps1` that emits Prometheus-style metrics (test count, coverage %, CI duration). Export to a metrics endpoint or GitHub Actions cache. Low value for a documentation repo. |

### 27. Deployment Observability

| Field | Value |
|-------|-------|
| Criterion | `deployment_observability` |
| Current | 0/1 |
| Value | 2 |
| Difficulty | 3 |
| ROI | **-1** |
| Solution | Requires a deployment system first. Add deploy notifications to Slack or GitHub Discussions on release. Not applicable until release automation is in place. |

### 28. Circuit Breakers

| Field | Value |
|-------|-------|
| Criterion | `circuit_breakers` |
| Current | 0/1 |
| Value | 2 |
| Difficulty | 3 |
| ROI | **-1** |
| Solution | Implement a circuit breaker pattern in `common.ps1` for `Invoke-Gh` that tracks consecutive failures and trips after a threshold. Low value since scripts use `$ErrorActionPreference='Stop'` (fail-fast) already. |

### 29. Deployment Frequency

| Field | Value |
|-------|-------|
| Criterion | `deployment_frequency` |
| Current | 0/1 |
| Value | 2 |
| Difficulty | 4 |
| ROI | **-2** |
| Solution | Requires defining what "deployment" means for a template repo. Could track downstream clone frequency or release cadence. Add a CD workflow that publishes the repo as a GitHub template on tag push. |

### 30. Error Tracking Contextualized

| Field | Value |
|-------|-------|
| Criterion | `error_tracking_contextualized` |
| Current | 0/1 |
| Value | 2 |
| Difficulty | 4 |
| ROI | **-2** |
| Solution | No Sentry SDK for PowerShell. Could write a custom error reporter that posts to a webhook (Discord, Slack) with stack trace and context on unhandled errors in `Invoke-Gh`. |

### 31. Feature Flag Infrastructure

| Field | Value |
|-------|-------|
| Criterion | `feature_flag_infrastructure` |
| Current | 0/1 |
| Value | 2 |
| Difficulty | 4 |
| ROI | **-2** |
| Solution | Add a simple feature flag system using environment variables or a `feature-flags.json` config file. Check flags in scripts before executing optional behavior. Low value for a documentation repo. |

### 32. Alerting Configured

| Field | Value |
|-------|-------|
| Criterion | `alerting_configured` |
| Current | 0/1 |
| Value | 2 |
| Difficulty | 4 |
| ROI | **-2** |
| Solution | Add GitHub Actions failure notifications via email or Slack webhook. Configure `on: workflow_run` to alert on failed CI runs. Requires an external notification endpoint. |

### 33. Error-to-Insight Pipeline

| Field | Value |
|-------|-------|
| Criterion | `error_to_insight_pipeline` |
| Current | 0/1 |
| Value | 2 |
| Difficulty | 4 |
| ROI | **-2** |
| Solution | Requires error tracking first. Could auto-create GitHub issues from CI failures using `actions/github-script`. Low value until error tracking is in place. |

### 34. Type Check

| Field | Value |
|-------|-------|
| Criterion | `type_check` |
| Current | 0/1 |
| Value | 2 |
| Difficulty | 5 |
| ROI | **-3** |
| Solution | No static type checker exists for PowerShell. `Set-StrictMode -Version Latest` provides runtime strictness. Could explore PESTER-based type assertion tests or custom AST analysis for type annotation validation. |

### 35. Product Analytics Instrumentation

| Field | Value |
|-------|-------|
| Criterion | `product_analytics_instrumentation` |
| Current | 0/1 |
| Value | 1 |
| Difficulty | 4 |
| ROI | **-3** |
| Solution | Not a product application. No user interactions to track. Could instrument skill usage telemetry but this raises privacy concerns. Defer indefinitely. |

### 36. Distributed Tracing

| Field | Value |
|-------|-------|
| Criterion | `distributed_tracing` |
| Current | 0/1 |
| Value | 1 |
| Difficulty | 5 |
| ROI | **-4** |
| Solution | No distributed system. No OpenTelemetry SDK for PowerShell. The forensic run log (`gh-init-*.log`) provides per-run tracing but is not distributed tracing. Defer indefinitely. |

---

## Summary

| Tier | Count | ROI Range | Action |
|------|-------|-----------|--------|
| Quick Wins | 10 | 2-3 | Implement next, highest ROI |
| Medium Effort | 14 | 0-1 | Schedule in upcoming sprints |
| Strategic Investments | 12 | -4 to -1 | Defer or skip if not applicable |

Closing all 10 Quick Win gaps would raise the pass rate from 29/65 (44.6%) to 39/65 (60.0%), crossing into Level 4. Closing all 24 Quick Win + Medium Effort gaps would reach 53/65 (81.5%), approaching Level 5.

# gh-issue-tracking-init scripts

PowerShell 7 operation scripts that the **`gh-issue-tracking-init`** skill composes to build a `plan → epic → story → task` issue hierarchy on GitHub (Issues + Projects v2), per [`../references/gh-issue-tracking-plan.md`](../references/gh-issue-tracking-plan.md).

There is **one script per operation**; the skill orchestrates them. Every script is **idempotent** and supports **`-DryRun`**.

This directory is **self-contained**: `common-auth.ps1`, `import-labels.ps1`, and `create-milestones.ps1` are vendored copies of the general-purpose repo utilities at `scripts/common-auth.ps1`, `scripts/import-labels.ps1`, and `scripts/create-milestones.ps1` (kept there too, since they're generic and not specific to this skill). This skill has no dependency on the repository-root `scripts/` directory.

## Prerequisites

- **PowerShell 7+** (`pwsh`).
- **GitHub CLI (`gh`)** authenticated (`gh auth status`). `$GITHUB_TOKEN` is honored by `gh`. Project operations require the **`project`** scope. The repo root also ships `scripts/gh-auth.ps1` and `scripts/test-github-permissions.ps1` for auth/scope validation, if you want extra checks beyond this skill's own bootstrap.
- **`gh` version note:** sub-issues are created via the **REST API** here, so this works even on older `gh` (e.g. 2.46) that lacks `gh issue create --parent`. Sub-issues, issue dependencies, and Projects v2 fields are all driven through `gh api` / `gh project`.

## Operations

| Script | Purpose | Key parameters |
| ------ | ------- | -------------- |
| `ensure-labels.ps1` | Create/update the canonical label taxonomy from `../assets/labels.json` (delegates to the vendored `import-labels.ps1`) | `-Repo [-LabelsFile]` |
| `ensure-project.ps1` | Create/link the Project and its custom fields (`Level`, `Priority`, `Estimate`, optional `Phase`); **prints the project number to stdout** (machine-readable, capture via `$()`) | `-Owner -Repo [-Title] [-Phases]` |
| `ensure-issue.ps1` | Create **or** update one issue from a filled template body; prints the issue **number** to stdout | `-Repo -Title (-BodyFile\|-Body) [-Labels -Milestone -Assignee -UpdateBody]` |
| `link-sub-issue.ps1` | Attach a child issue as a sub-issue of a parent | `-Repo -ParentNumber -ChildNumber` |
| `set-project-fields.ps1` | Add an issue to the board and set `Level/Priority/Phase/Status/Estimate` | `-Owner -ProjectNumber -Repo -IssueNumber [...]` |
| `set-dependency.ps1` | Record a "blocked by" relationship | `-Repo -IssueNumber -BlockedByNumber` |
| `assert-no-secrets.ps1` | Scan rendered issue-body files for secrets before `gh issue create`; **throws on confident detection** (throw-and-halt, no auto-redaction) | `-BodyFiles [-DryRun]` |

**Milestones** (conceptual work groups such as `POC`, `MVP`, `UI`, `Server`) are created with the vendored [`create-milestones.ps1`](./create-milestones.ps1) — no dedicated op script is needed.

Shared helpers live in `common.ps1` (auth bootstrap via the vendored `common-auth.ps1`, a mockable `Invoke-Gh` wrapper, `owner/repo` parsing, and the numeric-DB-id lookups the sub-issues and dependencies APIs require).

## Idempotency

Re-runs are safe. Labels, milestones, project fields, sub-issue links, and dependencies are matched against what already exists and are skipped or updated — never duplicated. Issues are matched by **exact numbered title** (e.g. `Epic 1: Inference`). `ensure-issue.ps1` updates labels/milestone on re-run but leaves the body untouched unless `-UpdateBody` is passed.

## Known limitations (surfaced honestly)

- **Project views are not automatable.** GitHub's CLI/API has no supported "create view" operation, so `ensure-project.ps1` prints the four views to add once in the Project UI: **By Phase, By Status, By Epic, Current work**.
- **Built-in `Status` options are limited.** `gh` cannot add options to an existing single-select field, so the initial set is `Todo / In Progress / Done`. If your workflow needs `In Review` or `Blocked`, add those once in the Project UI.
- **GitHub database IDs exceed Int32.** Global issue DB IDs now exceed `Int32.MaxValue` (2,147,483,647); `Get-IssueDbId` casts to `[long]`, which is why `link-sub-issue.ps1` and `set-dependency.ps1` work against modern repos (fixed in this release).

## Tests

```bash
pwsh -NoProfile -Command "Invoke-Pester -Path .agents/skills/gh-issue-tracking-init/scripts/tests -Output Detailed"
```

The Pester suite covers the `common.ps1` helper logic (with `gh` mocked), the label taxonomy, per-script contracts (parse cleanly, expose `-DryRun`, reject malformed `-Repo`), and self-containment (the three vendored scripts are present locally). It performs **no repo mutation**.

## Smoke test (run against a throwaway repo)

Full end-to-end validation is intentionally user-driven against a **dedicated test repo** (never production). Preview everything with `-DryRun` first, then drop it to apply. Run these from the repository root.

```pwsh
$Skill = './.agents/skills/gh-issue-tracking-init/scripts'
$Repo  = 'you/test-repo'
$Owner = 'you'

# 1. Preview
& "$Skill/ensure-labels.ps1"  -Repo $Repo -DryRun
& "$Skill/ensure-project.ps1" -Owner $Owner -Repo $Repo -DryRun
& "$Skill/create-milestones.ps1" -Repo $Repo -Titles 'MVP' -DryRun

# 2. Apply base scaffolding
& "$Skill/ensure-labels.ps1"  -Repo $Repo
$Proj = & "$Skill/ensure-project.ps1" -Owner $Owner -Repo $Repo   # captures the project number from stdout (e.g. 3)
& "$Skill/create-milestones.ps1" -Repo $Repo -Titles 'MVP'

# 3. Build a tiny plan -> epic -> story -> task tree (capture the printed numbers)
$plan  = & "$Skill/ensure-issue.ps1" -Repo $Repo -Title 'Plan: Test'          -Body 'plan'  -Labels plan
$epic  = & "$Skill/ensure-issue.ps1" -Repo $Repo -Title 'Epic 1: Core'         -Body 'epic'  -Labels epic  -Milestone MVP
$story = & "$Skill/ensure-issue.ps1" -Repo $Repo -Title 'Story 1.1: Bootstrap' -Body 'story' -Labels story -Milestone MVP
$task  = & "$Skill/ensure-issue.ps1" -Repo $Repo -Title 'Task 1.1.1: Init'     -Body 'task'  -Labels task  -Milestone MVP

# 4. Link the hierarchy
& "$Skill/link-sub-issue.ps1" -Repo $Repo -ParentNumber $plan  -ChildNumber $epic
& "$Skill/link-sub-issue.ps1" -Repo $Repo -ParentNumber $epic  -ChildNumber $story
& "$Skill/link-sub-issue.ps1" -Repo $Repo -ParentNumber $story -ChildNumber $task

# 5. Set board fields (use the project number captured in step 2)
& "$Skill/set-project-fields.ps1" -Owner $Owner -ProjectNumber $Proj -Repo $Repo -IssueNumber $epic -Level epic -Priority P1 -Status 'Todo'
& "$Skill/set-project-fields.ps1" -Owner $Owner -ProjectNumber $Proj -Repo $Repo -IssueNumber $task -Level task -Priority P2 -Status 'Todo'

# 6. Dependencies (optional)
& "$Skill/set-dependency.ps1" -Repo $Repo -IssueNumber $task -BlockedByNumber $story

# 7. Validate: sub-issues, milestone rollup, and dependencies
gh api "repos/$Repo/issues/$epic/sub_issues" --jq '.[].title'
gh api "repos/$Repo/issues/$task/dependencies/blocked_by" --jq '.[].title'
```

Re-running steps 2–6 should report skips/updates and create no duplicates.

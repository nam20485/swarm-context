# gh-issue-tracking-init

An AI agent skill that initializes (or re-syncs) a GitHub issue-based planning
hierarchy for a repository: a `plan → epic → story → task` tree of linked
sub-issues, backed by a GitHub Project (v2) board, milestones, and labels.

This file is the human-facing overview. For the agent-facing trigger/orchestration
contract, see [`SKILL.md`](./SKILL.md). For script-level reference, see
[`scripts/README.md`](./scripts/README.md).

---

## What it does

Given a target repository (`$ghrepo`) and a plan (a filled plan document, or a
description of the epics/stories/tasks), this skill builds out:

> **Both inputs are optional.** With no arguments, `$ghrepo` defaults to the repo
> the skill is running from (`gh repo view --json nameWithOwner`), and the plan
> source is resolved **non-interactively** from `plan_docs/` — the primary
> development plan (e.g. `development-plan.md`) drives the issue tree, while
> architecture/reference docs (e.g. `architecture-guide`, strategic context) are
> folded into the Plan issue body as supporting context.
> See [Inputs](./SKILL.md#inputs) in `SKILL.md`.

1. **A canonical label taxonomy** — level labels (`plan`, `epic`, `story`, `task`),
   priority labels (`P0`–`P3`), area labels, and cross-cutting status labels
   (`blocked`, `needs-review`, `wontfix`).
2. **Milestones** — conceptual work groups (e.g. `POC`, `MVP`, `UI`, `Server`),
   assigned to each epic and all of its descendants.
3. **A GitHub Project (v2) board** with custom fields (`Level`, `Priority`,
   `Estimate`, and an optional `Phase`) for tracking work.
4. **The issue hierarchy itself** — one GitHub issue per plan/epic/story/task,
   created from the templates in
   [`assets/templates/`](./assets/templates/),
   with numbered titles (`Plan: <Name>`, `Epic 1: <Name>`, `Story 1.1: <Name>`,
   `Task 1.1.1: <Name>`).
5. **Sub-issue links** connecting every parent to its children.
6. **Blocking/blocked-by dependencies** between issues, where the plan calls for them.

The full design rationale (why sub-issues instead of task lists, why phases and
milestones are separate axes, the label taxonomy, etc.) lives in the skill's own
[`references/gh-issue-tracking-plan.md`](./references/gh-issue-tracking-plan.md).

## How it works

### Architecture

```text
gh-issue-tracking-init/
├─ README.md           <- you are here (human overview)
├─ SKILL.md             <- agent-facing trigger + orchestration contract
├─ assets/              <- data + issue body templates (consumed via -BodyFile)
│  ├─ labels.json                the canonical label taxonomy (data)
│  └─ templates/                 issue body templates, one per hierarchy level
│     ├─ application-plan.md        plan-level issue body
│     ├─ epic.md                    epic-level issue body
│     ├─ story.md                   story-level issue body
│     └─ task.md                    task-level issue body
├─ references/          <- design reference loaded into context as needed
│  └─ gh-issue-tracking-plan.md  full design plan (hierarchy model, conventions)
└─ scripts/             <- self-contained PowerShell operation scripts
   ├─ common.ps1                 shared helpers (auth, gh wrapper, id lookups)
   ├─ common-auth.ps1            vendored: gh CLI auth bootstrap
   ├─ import-labels.ps1          vendored: generic label import/sync
   ├─ create-milestones.ps1      vendored: generic milestone creation
   ├─ ensure-labels.ps1          op: sync assets/labels.json to a repo
   ├─ ensure-project.ps1         op: create/link Project + custom fields
   ├─ ensure-issue.ps1           op: idempotent create/update one issue
   ├─ link-sub-issue.ps1         op: attach a child issue as a sub-issue
   ├─ set-project-fields.ps1     op: add issue to board + set field values
   ├─ set-dependency.ps1         op: record a "blocked by" relationship
   ├─ README.md                  script-level reference + smoke test
   └─ tests/
      └─ GhIssueTracking.Tests.ps1   Pester suite (29 tests)
```

- **The skill** (`SKILL.md`) is what an AI agent reads to decide *what* to build
  from a plan and in what order. It doesn't contain any executable code — it's
  a Markdown contract describing inputs, conventions, and an ordered sequence of
  script invocations.
- **The scripts** (`scripts/`) do the actual work. There is **one script per
  discrete GitHub operation** (not one big script), so the skill composes small,
  independently-testable pieces rather than running one monolithic routine.
- **Self-contained:** all skill content lives under this directory —
  `common-auth.ps1`, `import-labels.ps1`, and `create-milestones.ps1` are
  vendored (copied) into `scripts/` from the repository-root `scripts/`
  directory (where general-purpose copies also live); the label taxonomy ships
  as `assets/labels.json`, the issue body templates ship in
  `assets/templates/`, and the design plan ships in `references/`. This skill
  has zero dependency on anything outside its own folder — you can copy
  `gh-issue-tracking-init/` into another repo and it will work unmodified.

### Design principles

- **Sub-issues are the only hierarchy mechanism.** GitHub's older "tasklist
  block" feature (which linked checklist items to child issues) was retired in
  April 2025 in favor of native sub-issues. This skill uses sub-issues
  exclusively for parent↔child relationships; plain markdown checklists are
  only used for in-issue items like acceptance criteria, never for hierarchy.
- **Idempotent by design.** Every script matches what already exists (by exact
  issue title, by label name, by milestone title, by existing sub-issue link,
  by existing dependency) and skips or updates rather than duplicating. The
  whole skill can be re-run safely after the plan changes.
- **Dry-run everywhere.** Every operation script accepts `-DryRun` and prints
  exactly what it *would* do without mutating anything.
- **Two independent grouping axes.** *Phase* (an optional Project field) is for
  pushing large chunks of work into a future development effort; *Milestone*
  (a native GitHub milestone) is for conceptual groups like `MVP` or `UI`. An
  epic can carry both, independently.
- **Status lives on the board, not in labels.** Workflow state (`Todo`, `In
  Progress`, `Done`, ...) is the Project's built-in `Status` field — labels are
  reserved for level, priority, area, and cross-cutting flags.

## How to use it

### As an AI agent skill

Ask an agent that has this skill available to set up issue tracking for a repo,
e.g.:

> "Set up GH issue tracking for `owner/repo` using this plan: ..."
> "Initialize the plan/issue hierarchy in `owner/repo`."
> "Set up GH issue tracking." *(no args — defaults to the current repo and `plan_docs/`)*

The agent reads [`SKILL.md`](./SKILL.md), parses your plan into the numbered
plan→epic→story→task structure, and composes the scripts below — always doing a
`-DryRun` pass first and showing you the plan before applying it.

### Manually, by running the scripts directly

You don't need an AI agent to use this — every script works standalone. Run
them from the repository root (or adjust the path):

```pwsh
$Skill = './.agents/skills/gh-issue-tracking-init/scripts'
$Repo  = 'owner/repo'
$Owner = 'owner'

# 1. Labels, milestones, and the Project (always preview first)
& "$Skill/ensure-labels.ps1"     -Repo $Repo -DryRun
& "$Skill/ensure-project.ps1"    -Owner $Owner -Repo $Repo -DryRun
& "$Skill/create-milestones.ps1" -Repo $Repo -Titles 'MVP' -DryRun

# 2. Apply once you're happy with the preview (drop -DryRun)
& "$Skill/ensure-labels.ps1"     -Repo $Repo
& "$Skill/ensure-project.ps1"    -Owner $Owner -Repo $Repo   # note the printed project number
& "$Skill/create-milestones.ps1" -Repo $Repo -Titles 'MVP'

# 3. Create issues top-down (each call prints the new/matched issue number)
$epic = & "$Skill/ensure-issue.ps1" -Repo $Repo -Title 'Epic 1: Core' -BodyFile ./epic1.md -Labels epic -Milestone MVP

# 4. Link hierarchy, set board fields, and record dependencies
& "$Skill/link-sub-issue.ps1"     -Repo $Repo -ParentNumber $plan -ChildNumber $epic
& "$Skill/set-project-fields.ps1" -Owner $Owner -ProjectNumber 3 -Repo $Repo -IssueNumber $epic -Level epic -Priority P1 -Status Todo
& "$Skill/set-dependency.ps1"     -Repo $Repo -IssueNumber $task -BlockedByNumber $story
```

See [`scripts/README.md`](./scripts/README.md) for the full operation reference
(every script's parameters) and a complete worked example that builds a small
plan→epic→story→task tree end to end.

### Prerequisites

- **PowerShell 7+** (`pwsh`).
- **GitHub CLI (`gh`)**, authenticated (`gh auth status`) with the **`project`**
  scope. `$GITHUB_TOKEN` is honored automatically.
- Sub-issues, issue dependencies, and Projects v2 fields are driven through
  `gh api` / `gh project`, so this works even on `gh` versions that predate
  `gh issue create --parent` (verified against `gh` 2.46.0).

## Tests and how to use them

The Pester suite lives at
[`scripts/tests/GhIssueTracking.Tests.ps1`](./scripts/tests/GhIssueTracking.Tests.ps1)
and covers, **with no repo mutation**:

- `common.ps1`'s helper functions (`Get-RepoParts`, `Find-IssueNumberByTitle`,
  `Get-IssueDbId`, `Invoke-GhJson`) with `gh` fully mocked.
- The label taxonomy in `assets/labels.json` (canonical labels present; workflow-state
  labels like `in-progress`/`done` intentionally absent).
- Every operation script's **contract**: it parses without errors, it exposes a
  `-DryRun` switch, and it rejects a malformed `-Repo`.
- **Self-containment**: the three vendored helper scripts are actually present
  in this directory (not just referenced from elsewhere).

Run the full suite from the repository root:

```bash
pwsh -NoProfile -Command "Invoke-Pester -Path .agents/skills/gh-issue-tracking-init/scripts/tests -Output Detailed"
```

Or with a plain pass/fail summary:

```bash
pwsh -NoProfile -Command "Invoke-Pester -Path .agents/skills/gh-issue-tracking-init/scripts/tests"
```

**What the Pester suite does *not* cover:** actually creating/updating things
on GitHub — that requires a real, authenticated `gh` session against a real
repository. For that, run the **smoke test** documented in
[`scripts/README.md`](./scripts/README.md#smoke-test-run-against-a-throwaway-repo):
it walks through building and validating a complete tiny hierarchy
(plan → epic → story → task, with sub-issue links, board fields, and a
dependency) against a **throwaway test repository** — always preview with
`-DryRun` first, and never point it at a production repo. Re-running the same
steps should report skips/updates rather than creating duplicates, which is the
idempotency guarantee in action.

## Known limitations

- **Project views can't be created via `gh`/API.** `ensure-project.ps1` prints
  the four intended views (By Phase, By Status, By Epic, Current work) for you
  to add once in the Project UI.
- **Built-in `Status` field options.** `gh` 2.46 can't add options to an
  existing single-select field, so extra `Status` values (`In Review`,
  `Blocked`) may need a one-time manual add in the UI.

## Out of scope (for now)

- **The issue-implementation skill** — a separate, deferred skill that would
  pick the "current" issue to work on and implement it; this skill only builds
  the hierarchy.
- **Defects/bugs** — no `defect` level, label, or template. Adding `defect` as a
  board `Level` would require extending the Project single-select *after* field
  creation, which `gh`/API cannot do (options are only settable at creation);
  shipping it half-working would force a manual UI step on every re-run, so it
  is deferred until that can be fully automated.

## Bundled resources

- [`assets/labels.json`](./assets/labels.json) — the canonical label taxonomy
  (level, priority, area, and status labels) consumed by `ensure-labels.ps1`.
- [`assets/templates/`](./assets/templates/) — the four issue body templates
  (`application-plan.md`, `epic.md`, `story.md`, `task.md`) consumed
  by `ensure-issue.ps1` via `-BodyFile`. The application-plan and epic
  templates include epic-grouped implementation plan subsections and
  infrastructure hardening notes.
- [`references/gh-issue-tracking-plan.md`](./references/gh-issue-tracking-plan.md) —
  the full design plan (hierarchy model, conventions, label taxonomy).

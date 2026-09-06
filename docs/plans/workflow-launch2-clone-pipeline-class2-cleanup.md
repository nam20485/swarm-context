# Plan — workflow-launch2 clone-pipeline Class-2 cleanup (additive, backward-compatible)

| | |
| --- | --- |
| **Plan** | Add Class-2 cleanup + `/gh-issue-tracking-init` hierarchy dispatch to the clone pipeline in `nam20485/workflow-launch2`, without changing or breaking the existing `project-setup` / `orchestrate-dynamic-workflow` orchestration path that other templates still rely on |
| **Target repo** | `nam20485/workflow-launch2` (the external clone-creation launcher) |
| **Template repo** | `intel-agency/agent-context` (consumer of the new path) |
| **Status** | Active |
| **Date** | 2026-07-20 |
| **Related** | [`docs/plans/.deferred/template-content-strategy.md`](.deferred/template-content-strategy.md) (W1 post-clone reset strategy); [`docs/plans/upstream-handoff-identity-and-phase-warning.md`](upstream-handoff-identity-and-phase-warning.md) (handoff from downstream run); [`create-repo-with-plan-docs.ps1`](https://github.com/nam20485/workflow-launch2/blob/main/scripts/create-repo-with-plan-docs.ps1); [`trigger-project-setup.ps1`](https://github.com/nam20485/workflow-launch2/blob/main/scripts/trigger-project-setup.ps1); [`create-dispatch-issue.ps1`](https://github.com/nam20485/workflow-launch2/blob/main/scripts/create-dispatch-issue.ps1) |

---

## Context

When `agent-context` is used as a GitHub template, the existing
`create-repo-with-plan-docs.ps1` pipeline clones the template, seeds `plan_docs/`,
substitutes placeholder names/owners, rewrites the AGENTS.md identity label, and
commits everything to a new downstream instance. The pipeline's final trigger
step (`trigger-project-setup.ps1`) dispatches an orchestration workflow that is
**still required** by other templates using the legacy
`/orchestrate-dynamic-workflow $workflow_name = project-setup` flow.

For `agent-context`-seeded instances, that dispatch body is incompatible: the
correct follow-up is to invoke the `gh-issue-tracking-init` skill directly
against the freshly seeded `plan_docs/`, and we also want a Class-2 cleanup step
(memory reset, template plans cleared, foreign artifacts removed) before the
seed commit.

## Constraints

1. **Backward compatibility** — existing script files are unchanged. The legacy
   `trigger-project-setup.ps1` body and the existing
   `create-repo-with-plan-docs.ps1` main loop keep working exactly as they do
   today, so other templates (`ai-new-workflow-app-template`,
   `gap-miner-v2-india89`, etc.) that rely on the legacy `project-setup`
   dispatch continue to function.
2. **Parallel new scripts** — the new capability is delivered as **new** script
   files in `nam20485/workflow-launch2/scripts/`, not as edits to existing ones.
3. **Additive integration** — the only change to `create-repo-with-plan-docs.ps1`
   is an optional `-SkipProjectSetup` switch that lets the caller skip the
   legacy trigger when they intend to invoke the new
   `trigger-gh-issue-tracking-init.ps1` as a separate step. Default behavior
   stays identical.
4. **Deterministic** — the new scripts are idempotent and safe to re-run against
   the same clone (cleanup skips missing files, the dispatch-issue creation
   asserts the issue body, label bootstrap is guarded with `Ensure-*`).

## Upstream-handoff triage (from [`upstream-handoff-identity-and-phase-warning.md`](upstream-handoff-identity-and-phase-warning.md))

| Handoff § | Issue | Status |
| --- | --- | --- |
| §1 | AGENTS.md identity mislabels clones as "upstream template" | **Resolved (template-side, symptom-fix).** The uncommitted change to `AGENTS.md` first paragraph (W1.4 option a in the strategy doc's analysis) reworded `**upstream GitHub template**` → `**GitHub template repo**` with a context-neutral apposition, so the existing `create-repo-with-plan-docs.ps1` anchor `**GitHub template repo**` → `**project instance** cloned from … GitHub template` now matches. Future work (explicitly out of scope for this plan): upstream handoff §1 also suggested runtime role detection (`gh repo view --json isTemplate -q .isTemplate`) — that would make the role label derive at read-time rather than from a single-shot label rewrite, and is architecturally better; deferred. |
| §1 reconcile | Which repo is the true canonical template | **Resolved.** `intel-agency/agent-context` is the canonical template (declared in `AGENTS.md:5` and in `docs/plans/.deferred/template-content-strategy.md`). The india89 plan docs that reference it as `TemplateRepoName` are a downstream-specific artifact that landed via the same Class-2 contamination W1 is fixing; W1.2 (clear template plans) removes them from future clones. |
| §2 | `set-project-fields.ps1` emits spurious `Phase` warning on every call | **Needs fix in this repo (agent-context), NOT in workflow-launch2.** Root cause confirmed at `.agents/skills/gh-issue-tracking-init/scripts/set-project-fields.ps1:95` — uses `if ($null -ne $Phase)` but unbound `[string]` parameters in PowerShell are `""` (empty), not `$null`, so the guard always passes. Same latent flaw affects `$Level`, `$Priority`, `$Status`. Already correctly handled for `$Estimate` at line 97 using `$PSBoundParameters.ContainsKey('Estimate')`. Fix: apply the same `ContainsKey` guard to all four single-select fields. Not covered by the uncommitted changes. Included in this plan as a parallel work item (§B below) since it's a one-file template-repo patch. |

## Work items

### §A — workflow-launch2 changes (additive, backward-compatible)

All three scripts below are **new files** in
`nam20485/workflow-launch2/scripts/`. No existing script is modified
except the optional `-SkipProjectSetup` switch added to
`create-repo-with-plan-docs.ps1` (default behavior unchanged).

#### §A.1 — `cleanup-template-state.ps1` (Class-2 cleanup)

A single-purpose script invoked once per clone, right after clone + placeholder
replace but BEFORE `Copy-PlanDocs`. Runs idempotently:

```pwsh
.SYNOPSIS
    Remove Class-2 template state from a freshly cloned agent-context instance.

.DESCRIPTION
    Deletes the template's `.agents/memory.md` and emits a minimal blank skeleton
    (section headers only, empty Current Activity). Removes the template's own
    completed and deferred plans from `docs/plans/.completed/` and
    `docs/plans/.deferred/`. Deletes `docs/plans/.completed/run-issues-review/`
    entirely (downstream-specific run reports that leaked into the template).
    Idempotent — skips paths that are not present.

.PARAMETER RepoRoot
    Absolute path to the freshly cloned repository working directory.

.PARAMETER DryRun
    Log planned operations without touching the filesystem.
```

Behavioral contract (for testing):

- **Memory reset**: deletes `.agents/memory.md`; writes back a skeleton with
  `# Project Memory`, sections `## Current Activity`,
  `## Completed Work Items`, `## Decisions`, `## Remember To Do` (each with an
  italic placeholder line describing the section's purpose). Emit inline so the
  pipeline is self-contained — no template `assets/` file is consumed.
- **Clear template plans**: removes every `*.md` file directly under
  `docs/plans/.completed/` and `docs/plans/.deferred/` (the template's own plans).
  Preserves the lifecycle directories themselves.
- **Remove foreign artifacts**: removes the entire
  `docs/plans/.completed/run-issues-review/` directory if present.
- **Idempotency**: missing paths are logged and skipped; running twice against
  the same clone is a no-op.
- **Order of operations**: cleanup first, then placeholder replacement, so
  `Update-TemplatePlaceholders` doesn't substitute into files we're about to
  delete.

#### §A.2 — `trigger-gh-issue-tracking-init.ps1` (hierarchy dispatch)

A new trigger that dispatches `/gh-issue-tracking-init` directly via
`create-dispatch-issue.ps1` — bypassing the legacy
`/orchestrate-dynamic-workflow project-setup` body that `trigger-project-setup.ps1`
emits. Reuses the existing `Ensure-DispatchBootstrapLabel` helper (dot-sourced
from `trigger-project-setup.ps1` or copied into a small shared
`dispatch-label-helpers.ps1` if we want to avoid cross-dot-sourcing).

```pwsh
.SYNOPSIS
    Trigger `/gh-issue-tracking-init` on a freshly seeded agent-context clone.

.DESCRIPTION
    Creates an `orchestration:dispatch`-labeled issue on the target repo whose
    body is simply `/gh-issue-tracking-init` (no args — the skill's defaults
    resolve to the current repo + seeded plan_docs/).

.PARAMETER Repo
    Target repository in "owner/repo" form.

.PARAMETER BootstrapLabelsFile
    Path to the clone's `.github/.labels.json` used to bootstrap the
    orchestration:dispatch label if it doesn't yet exist.

.PARAMETER DryRun
    Show what would be created without making any changes.
```

Behavioral contract:

- Issue title: `gh-issue-tracking-init` (matches the `create-dispatch-issue.ps1`
  convention: short, verb-leading command name).
- Issue body: a single-line dispatch trigger whose body is exactly
  `/gh-issue-tracking-init` (no args — the skill's defaults resolve to the
  current repo + `plan_docs/`, exactly the post-clone state).
- Calls the existing `create-dispatch-issue.ps1` for issue creation; does not
  duplicate its argument-list construction.
- Ensures the `orchestration:dispatch` label exists via
  `Ensure-DispatchBootstrapLabel` so the orchestrator that matches the label
  picks up the issue.

#### §A.3 — `create-repo-agent-context.ps1` (new orchestrator)

A thin wrapper that runs the existing `create-repo-with-plan-docs.ps1` with
`-SkipProjectSetup` (suppressing the legacy trigger), then invokes
`cleanup-template-state.ps1` on the clone, then invokes
`trigger-gh-issue-tracking-init.ps1` against it. Keeps the old code path
untouched.

```pwsh
.SYNOPSIS
    Create a new `agent-context`-seeded repo with Class-2 cleanup and
    `/gh-issue-tracking-init` hierarchy dispatch.

.DESCRIPTION
    Thin wrapper over create-repo-with-plan-docs.ps1 + cleanup-template-state.ps1
    + trigger-gh-issue-tracking-init.ps1. Accepts the same core parameters as
    create-repo-from-slug.ps1 (Slug, Owner, Visibility, Count, Yes, LaunchAgent)
    plus the agent-context-specific ones (-TriggerHierarchyInit, default $true).
    The legacy project-setup dispatch is never fired by this wrapper.
```

Behavioral contract:

- Accepts `$Slug`, `$Owner`, `$Visibility`, `$Count`, `$Yes`, `$LaunchAgent`.
- Hard-codes `$TemplateRepoName = 'agent-context'` and
  `$TemplateOwner = 'intel-agency'` (the canonical template identity).
- Hard-codes `$PlanDocsDir = "./plan_docs/$Slug"` (launcher convention).
- Hard-codes `$CloneParentDir = '../dynamic_workflows'`.
- Forwards to `create-repo-with-plan-docs.ps1` with `-SkipProjectSetup`.
- For each created repo path, runs `cleanup-template-state.ps1` +
  `trigger-gh-issue-tracking-init.ps1` in sequence.
- Amends the seed commit with the cleanup changes and force-pushes
  (mirrors the existing template-race rebase path in
  `create-repo-with-plan-docs.ps1` — the `Invoke-GitCommitAndPush` helper
  already supports this).

#### §A.4 — Optional switch on `create-repo-with-plan-docs.ps1`

The only non-additive change. Add one switch parameter:

```pwsh
[Parameter(ParameterSetName = 'Create', HelpMessage = 'Skip the legacy project-setup trigger at the end of creation. Intended for callers that invoke trigger-gh-issue-tracking-init.ps1 as a separate step.')]
[switch]$SkipProjectSetup,
```

and gate the existing trigger block (`lines 403-423`) on `if ($TriggerProjectSetup -and -not $SkipProjectSetup)`. Default behavior (no flag) is identical to today: legacy trigger fires. Callers that opt into the new path set `-SkipProjectSetup` and run `trigger-gh-issue-tracking-init.ps1` themselves.

#### §A.5 — Pester coverage

Add a new test file `scripts/create-repo-agent-context.Tests.ps1` covering:

- `cleanup-template-state.ps1` on a synthetic clone fixture:
  - `.agents/memory.md` is reset to the skeleton shape.
  - `docs/plans/.completed/*.md` / `.deferred/*.md` files are deleted; dirs remain.
  - `docs/plans/.completed/run-issues-review/` is deleted.
  - Running twice is a no-op.
  - `-DryRun` logs but does not modify.
- `trigger-gh-issue-tracking-init.ps1`:
  - Dispatch issue body is exactly `/gh-issue-tracking-init`.
  - `orchestration:dispatch` label is bootstrapped before issue creation.
- `create-repo-agent-context.ps1`:
  - Calls `create-repo-with-plan-docs.ps1` with `-SkipProjectSetup`.
  - Calls cleanup before `trigger-gh-issue-tracking-init.ps1`.

The existing `TestTriggerProjectSetup.ps1` and any tests exercising
`trigger-project-setup.ps1` remain untouched.

### §B — agent-context template changes (set-project-fields Phase guard)

Single-file patch in this repo (agent-context), independent of §A:

**File:** `.agents/skills/gh-issue-tracking-init/scripts/set-project-fields.ps1`
**Lines:** 92–96

Change the four `$null -ne $X` guards to use `$PSBoundParameters.ContainsKey(...)`,
matching the existing pattern for `$Estimate` (line 97):

```pwsh
$singleSelect = [ordered]@{}
if ($PSBoundParameters.ContainsKey('Level'))    { $singleSelect['Level'] = $Level }
if ($PSBoundParameters.ContainsKey('Priority')) { $singleSelect['Priority'] = $Priority }
if ($PSBoundParameters.ContainsKey('Phase'))    { $singleSelect['Phase'] = $Phase }
if ($PSBoundParameters.ContainsKey('Status'))   { $singleSelect['Status'] = $Status }
$hasEstimate = $PSBoundParameters.ContainsKey('Estimate')
```

Add a Pester case under the existing
`.agents/skills/gh-issue-tracking-init/scripts/*.Tests.ps1` (or create one if
absent) that splats `@{ Owner = 'a'; ProjectNumber = 1; Repo = 'a/b'; IssueNumber = 2 }`
(no `$Phase`), runs under `-WhatIf`/`-DryRun`, and asserts:

- `$singleSelect` does **not** contain a `Phase` key.
- No `WARNING: Field 'Phase' not found` is emitted to the warning stream.

Existing test suite remains green.

## Execution order

**Step 1.** Implement §A.4 (optional switch) and §A.1–§A.3 (new scripts) in
`workflow-launch2`, with §A.5 Pester coverage.

**Step 2.** Implement §B in `agent-context` (one-file patch + Pester case).

**Step 3.** Verify end-to-end by picking an existing slug (e.g. `gap-miner-v2`)
and invoking the new orchestrator:

```pwsh
./scripts/create-repo-agent-context.ps1 `
    -Slug "gap-miner-v2" -TriggerHierarchyInit $true -Yes
```

Then, against the created throwaway clone, assert:

- `.agents/memory.md` contains only the blank skeleton.
- `docs/plans/.completed/` and `.deferred/` dirs are empty (lifecycle dirs
  preserved).
- `docs/plans/.completed/run-issues-review/` is gone.
- `AGENTS.md:5` in the template still reads "…**GitHub template repo**…"; in the
  clone it reads "…**project instance** cloned from the
  `intel-agency/agent-context` GitHub template…" (end-to-end confirmation of
  W1.4's fix).
- A dispatch issue exists on the new repo with body
  `/gh-issue-tracking-init` (not `/orchestrate-dynamic-workflow`).
- `gh-issue-tracking-init` with no args resolves to the clone + seeded
  `plan_docs/` (no regression).

**Step 4.** Verify the legacy path still works by picking a legacy-template slug
and invoking the existing wrapper:

```pwsh
./scripts/create-repo-from-slug.ps1 `
    -Slug "{legacy-slug}" -TemplateRepoName "ai-new-workflow-app-template" `
    -Yes
```

Assert that the `/orchestrate-dynamic-workflow $workflow_name = project-setup`
dispatch issue is still created on the new repo (regression check —
`trigger-project-setup.ps1` untouched).

## Out of scope

- **Removing or deprecating `trigger-project-setup.ps1`.** Other templates
  still use it; it stays.
- **Editing `create-repo-with-plan-docs.ps1` beyond the optional switch.** The
  main loop, placeholder logic, AGENTS.md rewrite, and rebase handling all stay
  verbatim.
- **Runtime AGENTS.md role detection** (handoff §1's "derive from
  `gh repo view --json isTemplate`"). Architecturally cleaner than a
  single-shot label rewrite but requires the AGENTS.md reader (an AI agent,
  not a script) to run `gh` at read-time. Tracked as a separate future
  enhancement, not part of this plan.
- **The strategy doc revisions themselves** — those belong in
  `docs/plans/.deferred/template-content-strategy.md` and are a separate edit
  from the implementation scripts.

## Validation

- `npx --no-install markdownlint-cli2` clean on this file.
- §A.5 Pester suite green in `workflow-launch2`.
- §B Pester case green in `agent-context`; existing skill tests stay green.
- End-to-end §3 verification against a throwaway clone.
- End-to-end §4 legacy-path regression against a legacy-template slug.

## Success criteria

- **Backward compatibility preserved:** running the legacy entry point
  (`create-repo-from-slug.ps1` without `-SkipProjectSetup` and with a
  non-agent-context template) produces the exact same dispatch issue body
  (`/orchestrate-dynamic-workflow $workflow_name = project-setup`) as today.
- **agent-context clones are clean:** a clone created via
  `create-repo-agent-context.ps1` has blank memory, no template plans, no
  `run-issues-review/`, a correctly-rewritten AGENTS.md first paragraph, and a
  `/gh-issue-tracking-init` dispatch issue (not the legacy project-setup one).
- **Phase warning silenced:** `set-project-fields.ps1` invoked without `-Phase`
  emits no warning, regardless of whether `Level`, `Priority`, or `Status` were
  also omitted.

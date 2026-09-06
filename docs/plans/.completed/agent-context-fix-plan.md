# Plan — Upstream fixes in `intel-agency/agent-context`

> Handoff document for an implementing agent. Source: the forensic analysis `gap-miner-v2-sierra46-forensic-analysis.md` (§9, §10) in the [`intel-agency/gap-miner-v2-sierra46`](https://github.com/intel-agency/gap-miner-v2-sierra46) repo. Target repo: [`intel-agency/agent-context`](https://github.com/intel-agency/agent-context) (the parent template that owns the `/gh-issue-tracking-init` skill as the canonical source of truth).

| | |
|---|---|
| **Plan** | Forensic-fixes upstream in agent-context |
| **Target repo** | `intel-agency/agent-context` |
| **Date drafted** | 2026-07-17 |
| **Status** | Implemented (W1, W2, W4); W3 (defect level) **deferred** — extracted to [`../.deferred/defect-level-plan.md`](../.deferred/defect-level-plan.md) |
| **Skill path in target** | `.agents/skills/gh-issue-tracking-init/` |
| **Generic scripts path** | `scripts/` (the repo-root `common-auth.ps1`, `import-labels.ps1`, `create-milestones.ps1`) |

---

## TL;DR

A forensic analysis of the skill applied to `intel-agency/gap-miner-v2-sierra46` found one **latent Int32-overflow bug**, two documentation gaps, and one missing level (`defect`). This plan fixes all of it **upstream** in `intel-agency/agent-context` so downstream repos inherit the improvements the next time they vendor the skill. Per-repo manual steps (adding Project views, tweaking Status options, adding plan-issue context) are out of scope.

---

## 1. Scope & Inputs

- **Target repo:** `intel-agency/agent-context` (the repo that owns the `/gh-issue-tracking-init` skill as its canonical source of truth)
- **Skill path in target:** `.agents/skills/gh-issue-tracking-init/`
- **Generic scripts path:** `scripts/` (the repo-root `common-auth.ps1`, `import-labels.ps1`, `create-milestones.ps1`)
- **Evidence:** the forensic analysis `gap-miner-v2-sierra46-forensic-analysis.md` (`§9`, `§10`) in the [`intel-agency/gap-miner-v2-sierra46`](https://github.com/intel-agency/gap-miner-v2-sierra46) repo
- **Fixes applied upstream flow forward:** once W1–W4 merge into `agent-context`, any repo cloned from the template afterward inherits them automatically.

### In scope (work items below)

- **W1.** Fix the `Int32` overflow in `Get-IssueDbId` + add a Pester regression test.
- **W2.** Add subagent-batching guidance to `SKILL.md`.
- **W3.** Add a `defect` level label + issue template + Pester coverage.
- **W4.** Tighten `scripts/README.md` and `SKILL.md` with the known limitations surfaced by the forensic run (views not automatable, extra Status options needing UI).

### Out of scope

Per-repo UI/curator items (project views, extra `Status` options, plan-issue prose, dependency-DAG review). These remain the concern of whichever operator runs the hierarchy on any given repo and are not upstream template work.

---

## 2. Orientation for the implementing agent

Before starting:

1. Clone/fetch `intel-agency/agent-context` and `cd` into it.
2. Verify the skill lives at `.agents/skills/gh-issue-tracking-init/`; verify its `scripts/` directory matches the file list expected by the skill README.
3. Confirm prerequisites: `pwsh` 7+, `gh` authenticated with the `project` scope, `Pester` installed (`Install-Module Pester -Force -Scope CurrentUser` or similar).
4. Run the existing Pester suite to establish a green baseline:
   ```bash
   pwsh -NoProfile -Command "Invoke-Pester -Path .agents/skills/gh-issue-tracking-init/scripts/tests -Output Detailed"
   ```

---

## 3. Work items

### W1 — Fix `Int32` overflow in `Get-IssueDbId` + regression test (HIGH)

- **Owner:** Implementing agent
- **Prerequisites:** Orientation (step 2) green
- **Scope:** `.agents/skills/gh-issue-tracking-init/scripts/common.ps1` and `scripts/tests/GhIssueTracking.Tests.ps1`

**Changes**

1. `common.ps1:99` — change:
   ```powershell
   # Before
   return [int]$rawId
   # After
   return [long]$rawId
   ```
   The `[int]$Number` parameter (issue *number*) correctly stays `[int]` — issue numbers are small.
2. Scan the entire skill directory (and the repo-root `scripts/` generic helpers) for other `[int]` casts of *database* ids. `Find-IssueNumberByTitle` casts `$match.number` (small, safe) — leave it. The only required change is the one above.
3. Add a Pester regression test in `scripts/tests/GhIssueTracking.Tests.ps1`:
   - Mock `gh api repos/*/issues/<n> --jq '.id'` to return `4916360172` (or any value > `2147483647`).
   - Assert `Get-IssueDbId` returns that exact `[long]` value without throwing.
   - Assert the return type is `[long]` / assignable to `[int64]`.

**Acceptance Criteria**

- [ ] `common.ps1:99` reads `return [long]$rawId`.
- [ ] New Pester test `returns a long when gh reports an id greater than Int32.MaxValue` passes.
- [ ] Full Pester suite (`Invoke-Pester -Path ... -Output Detailed`) green with no new failures.
- [ ] `scripts/common-auth.ps1`, `scripts/import-labels.ps1`, `scripts/create-milestones.ps1` (repo-root generic copies) inspected; if any copy contains a similar `[int]$rawId` cast it receives the same fix and same test.

**Reference**

- Forensic findings §9.1, issue F1.

---

### W2 — Add subagent-batching guidance to `SKILL.md` (HIGH)

- **Owner:** Implementing agent
- **Prerequisites:** Orientation (step 2) green
- **Scope:** `.agents/skills/gh-issue-tracking-init/SKILL.md` (and optionally `scripts/README.md`)

**Changes**

1. Add a new H2 section to `SKILL.md`, e.g. `### Delegation performance (batching)` immediately after `Orchestration steps`. The guidance, in substance:
   - Do not invoke each op script one at a time with an LLM reasoning loop between calls — this has been measured at ~77 min for ~40% of a 30-issue hierarchy.
   - Instead, **compose a single PowerShell orchestration script** that builds an issue map, loops `ensure-issue.ps1`, then `link-sub-issue.ps1`, then `set-project-fields.ps1`, then `set-dependency.ps1`, with `Start-Sleep -Milliseconds` between REST-mutating calls to avoid secondary rate limits.
   - Provide the canonical hashtable-splatting pattern for `set-project-fields.ps1` calls:
     ```powershell
     $ht = @{ Owner=$Owner; ProjectNumber=$Proj; Repo=$Repo; IssueNumber=$n; Level='story'; Status='Todo'; Priority='P1'; Phase='X' }
     & "$Skill/set-project-fields.ps1" @ht
     ```
     **Important:** array-splat (`@a` of a `string[]`) is positional and will misbind parameter names — always use hashtable splatting with this script.
2. Cross-link to the forensic doc or a short inline "gotchas" callout.

**Acceptance Criteria**

- [ ] `SKILL.md` contains a clearly-marked section on delegation performance.
- [ ] The section includes both the anti-pattern (one script per LLM turn) and the recommended pattern (single composed PowerShell script with hashtable splatting).
- [ ] The section includes the exact hashtable-splattern shown above (this was the only call-site bug in the forensic run).

**Reference**

- Forensic findings §9.4, issue F8.

---

### W3 — Add a `defect` level label + issue template (LOW) — DEFERRED

> **Deferred (2026-07-18).** The defect level was descoped from this plan and extracted into a standalone deferred plan: [`../.deferred/defect-level-plan.md`](../.deferred/defect-level-plan.md). `assets/labels.json` currently ships `plan / epic / story / task` (no `defect`), and no `ISSUE_TEMPLATE/` directory exists; `SKILL.md` documents defects as deferred. The original W3 spec is retained below for the historical record.

- **Owner:** Implementing agent
- **Prerequisites:** W1 + W2 complete (Pester baseline green; test harness healthy)
- **Scope:** `.agents/skills/gh-issue-tracking-init/scripts/labels.json`, `ISSUE_TEMPLATE/defect.md`, `SKILL.md`, `scripts/tests/GhIssueTracking.Tests.ps1`

**Changes**

1. `labels.json` — append:
   ```json
   { "name": "defect", "color": "b60205", "description": "Level: defect / bug-fix task" }
   ```
2. Copy `ISSUE_TEMPLATE/task.md` to `ISSUE_TEMPLATE/defect.md`; adjust the front-matter (`name: Defect`, `labels: ['defect']`) and the header to `# Defect: [Short symptom]`. Body sections (Reproduction, Root Cause, Fix, Verification) are recommended but the defect template is otherwise minimal.
3. `SKILL.md`:
   - Add `defect` to the **Level labels** mention (`plan / epic / story / task / defect`).
   - Update the `ensure-issue.ps1` orchestration step to pass `-Level defect` when the defect template is used.
   - Update the "Out of scope" / "Definition of done" section that currently says defects are deferred — mark them supported as of this change.
4. Pester: the existing `labels.json` test should be extended (or a new test added) that asserts:
   - a `defect` entry is present;
   - `ISSUE_TEMPLATE/defect.md` exists;
   - the front-matter `name` and `labels` fields match the expected values.

**Acceptance Criteria**

- [ ] `defect` label in `labels.json`.
- [ ] `ISSUE_TEMPLATE/defect.md` exists with correct front-matter.
- [ ] `SKILL.md` documents `defect` as a supported level.
- [ ] Pester suite green (new test(s) included).
- [ ] Running `ensure-labels.ps1` on a throwaway repo creates the `defect` label via the vendored taxonomy.

**Reference**

- Issue F7.

---

### W4 — Tighten known-limitations section (LOW)

- **Owner:** Implementing agent
- **Prerequisites:** W1 + W2 complete
- **Scope:** `.agents/skills/gh-issue-tracking-init/scripts/README.md`, `SKILL.md`

**Changes**

1. Replace the current terse `Known limitations` / `Known limitations (surfaced honestly)` text with a richer version that lists:
   - **Project views are not automatable.** `gh`/API has no supported "create view" operation; `ensure-project.ps1` prints the four intended views for the user to add once in the Project UI: **By Phase, By Status, By Epic, Current work**.
   - **Built-in `Status` options limited.** `gh` cannot add options to an existing single-select field; the initial set is `Todo / In Progress / Done`. If the downstream workflow needs `In Review` or `Blocked`, those must be added once in the UI.
   - **GitHub DB ids exceed Int32** — fixed in this release (the `[long]` change). Call out that the fix is the reason `link-sub-issue.ps1` and `set-dependency.ps1` now work against modern repos.
2. SKILL.md: same list under its `Known limitations` section (so an agent reading the contract sees the limits at decision time, not only at script-reference time).

**Acceptance Criteria**

- [ ] Both READMEs list the three limitations above.
- [ ] No claim of "Status options are extensible via `gh`" remains anywhere in the skill docs.

**Reference**

- Issues F2, F3 (UI parts remain per-repo; this W addresses the *documentation* of the limitation).

---

## 4. Dependency graph

```
W1 (Int32 fix + Pester)  ──┬──▶ W2 (SKILL.md batching)
                            ├──▶ W3 (defect level)   [parallel-safe with W2]
                            └──▶ W4 (docs)           [parallel-safe with W2, W3]
```

W1 is the blocker (Pester must be green + the regression test in place) before doc changes land, so the docs can truthfully claim the Int32 issue is resolved.

W2/W3/W4 are independent of each other and may run in parallel.

---

## 5. Definition of done

The plan is done when, against `intel-agency/agent-context`:

1. [ ] All four work items (W1–W4) pass their individual acceptance criteria.
2. [ ] The full Pester suite passes:
   ```bash
   pwsh -NoProfile -Command "Invoke-Pester -Path .agents/skills/gh-issue-tracking-init/scripts/tests -Output Detailed"
   ```
3. [ ] The **smoke test** from `scripts/README.md` (run against a dedicated throwaway test repo) builds a tiny `plan → epic → story → task` hierarchy end-to-end without any Int32-overflow or splatting-misbind errors, and all sub-issue links and dependencies are recorded.
4. [ ] A PR opened against `intel-agency/agent-context`'s default branch:
   - uses a Conventional Commit message (`fix(gh-issue-tracking-init): handle Int64 DB ids + defect level + doc updates`);
   - links back to this plan and the forensic analysis in `sierra46`;
   - includes the Pester output and the smoke-test evidence in the PR description.

---

## 6. Issues that need to be addressed / resolved

> Complete checklist, ranked by severity. Checked items are the ones W1–W4 resolve above. Unchecked items are per-repo follow-ups that remain local after this upstream ship lands.

### High

- [x] **F1 — Fix the `Int32→Int64` cast in `common.ps1`** → resolved by **W1**.
- [ ] **F2 — Add the 4 Project v2 views (manual UI, not automatable)** → by-design manual. W4 documents the limitation. The README/SKILL callout tells operators to add **By Phase, By Status, By Epic, Current work** in the Project UI.

### Medium

- [ ] **F3 — Decide on extra `Status` options** → by-design manual. W4 documents the limitation so operators know `In Review` / `Blocked` need a one-time UI add.
- [ ] **F4 — Review dependency-edge completeness** → per-application decision; no upstream work.

### Low

- [ ] **F6 — Add a one-paragraph strategic summary to the plan issue (#1) body** → per-application narrative; no upstream work.
- [ ] **F7 — `defect` label + template** → **deferred** (was W3); see [`../.deferred/defect-level-plan.md`](../.deferred/defect-level-plan.md).
- [x] **F8 — Subagent performance lesson (batching guidance)** → resolved by **W2**.

---

## 7. Handoff to the implementing agent

```text
You are implementing a fix plan in intel-agency/agent-context. The fix plan is:
  docs/plans/agent-context-fix-plan.md

1. Orientation (steps 1–4 of the plan): clone/fetch the repo, locate the skill,
   run the existing Pester suite and confirm it is green at baseline.
2. Execute W1 (common.ps1 + Pester regression test). Re-run Pester — must be
   green, including the new oversized-id test.
3. Execute W2, W3, W4 (independent; parallel-safe). Re-run Pester after each —
   must remain green.
4. Run the smoke test from scripts/README.md against a dedicated throwaway test
   repo (not a production repo). Record which scripts succeeded, which skipped
   on idempotency, and any new errors.
5. Open a PR against the default branch of intel-agency/agent-context:
     - Conventional Commit: fix(gh-issue-tracking-init): handle Int64 DB ids +
       defect level + doc updates
     - PR body: link to this plan and to the forensic analysis document that
       motivated it; paste Pester output + smoke-test evidence.

Stop and escalate (do not guess) if:
  - the repo layout differs materially from what this plan assumes;
  - the existing Pester suite is not green at baseline;
  - the smoke test reveals a secondary overflow or misbinding anywhere else in
    the skill.
```

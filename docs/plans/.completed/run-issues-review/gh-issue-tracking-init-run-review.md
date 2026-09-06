# gh-issue-tracking-init — Execution Review & Issue Report

**Date:** 2026-07-16
**Target repo:** `intel-agency/gap-miner-v2-oscar32`
**Plan source:** `plan_docs/development-plan.md` (Gap Mining Platform v1.0)
**Skill:** `.agents/skills/gh-issue-tracking-init/` · driver: `/tmp/kilo/gh-init-driver.ps1`
**Project created:** #88 — https://github.com/orgs/intel-agency/projects/88

---

## 1. Executive summary

The skill was invoked to build a `plan → epic → story` issue hierarchy (30 issues: 1 plan, 7 epics, 22 stories), 7 milestones, a Projects v2 board with custom fields, sub-issue links, board field values, and 32 blocked-by dependencies.

**Outcome: partial failure.** The base scaffolding and top two hierarchy levels were created correctly, but the run broke during issue creation and never reached the linking / board-field / dependency steps.

| Stage | Status | Detail |
|------|--------|--------|
| 1/7 Labels (15) | ✅ Created | All canonical labels applied (`plan`,`epic`,`story`,`task`,`P0`–`P3`,`area/*`, status labels). |
| 2/7 Milestones (7) | ✅ Created | `Phase 0` … `Phase 6`. |
| 3/7 Project + fields | ✅ Created | Project **#88** under `intel-agency`, linked to repo; fields `Level`, `Priority`, `Estimate` created. |
| 4/7 Issues (30 planned) | ⚠️ Partial | **8 of 30** created: Plan `#1` + Epics `#2`–`#8`. **22 of 22 stories NOT created.** |
| 5/7 Sub-issue links | ❌ Skipped/failed | **0 links.** Epics are not sub-issues of the Plan; nothing is nested. |
| 6/7 Board fields | ❌ Skipped | Board has **0 items**; no `Level`/`Priority`/`Status` set. |
| 7/7 Dependencies (32) | ❌ Skipped | **0 of 32** blocked-by edges recorded. |

**Resulting repo state:** 8 correctly-labeled/milestoned issues exist (Plan + 7 Epics), each with a good body, but they are **flat, unlinked, and off the board**. The two problems the user spotted are both confirmed (§3).

---

## 2. Current GitHub repo state (verified)

- **Issues (8):**
  - `#1` Plan: Gap Mining Platform — label `plan`, no milestone, body present.
  - `#2` Epic 0: Environment & Foundation — `epic,P0,area/infra` · `Phase 0`
  - `#3` Epic 1: Domain & Data Layer — `epic,P1,area/core` · `Phase 1`
  - `#4` Epic 2: Scraper Pipeline — `epic,P1,area/core` · `Phase 2`
  - `#5` Epic 3: Intelligence Pipeline — `epic,P1,area/ai` · `Phase 3`
  - `#6` Epic 4: API Gateway — `epic,P2,area/core` · `Phase 4`
  - `#7` Epic 5: Blazor Dashboard — `epic,P2,area/ui` · `Phase 5`
  - `#8` Epic 6: Integration Testing & Hardening — `epic,P3,area/core` · `Phase 6`
- **Stories:** none exist (0 of 22).
- **Sub-issues:** none — `sub_issues` of `#1` and every epic `#2`–`#8` return empty.
- **Board (Project #88):** `items: [], totalCount: 0` — no issue has any field value.
- **Labels / Milestones:** all present and correct.
- **Epic bodies:** reference `Story 0.1 … Story 6.3` as checklist items pointing at issues that **do not yet exist** (dangling references).

---

## 3. User-reported problems — root cause

### Problem 1 — "Epics are not sub-issues of the main plan issue"
**Root cause:** a **PowerShell variable name case collision** in the driver.

PowerShell variable names are **case-insensitive**, so `$num` and `$Num` are the *same* variable. The driver declared a registry hashtable `$Num = @{}` but then, inside the creation loop, assigned the per-issue number to `$num`:

- `/tmp/kilo/gh-init-driver.ps1:472` — `$num = & ensure-issue.ps1 …`  → overwrites the registry with an **Int32** (e.g. `1`).
- `/tmp/kilo/gh-init-driver.ps1:473` — `$Num[$n.Key] = [int]$num` → now indexes an **Int32**, throwing:
  > `Unable to index into an object of type "System.Int32".`

Because the registry was destroyed after the very first issue, every later step that reads it failed:
- Linking: `$Num[$n.Parent]` (line 485) → `Method invocation failed because [System.Int32] does not contain a method named 'ContainsKey'`.
- Board fields (line 493) and dependencies (line 506) also depend on `$Num[…]` and were therefore never reached.

So the Plan and each Epic **were created**, but their numbers were never captured, and the hierarchy never got wired.

### Problem 2 — "No story issues"
**Root cause:** the **story data model omitted the `Level` key**, so no story body was ever written.

Story nodes were authored without `Level='story'` (first story, `/tmp/kilo/gh-init-driver.ps1:38`):
```powershell
@{ Key='0.1'; Parent='0'; TId='T-0.1'; Milestone='Phase 0'; Priority='P0'; Area='area/infra'; Title='Story 0.1: …'; … }
```
The body builder is dispatched by level:
- `/tmp/kilo/gh-init-driver.ps1:464` — `switch ($n.Level) { 'plan' {…} 'epic' {…} 'story' {…} }`.

For stories `$n.Level` is null → **no branch matches** → `Set-Content` is skipped → no body file is produced → `ensure-issue.ps1` throws `Body file not found: /tmp/kilo/gh-bodies/0.1.md` for **all 22 stories**. (Confirmed: only `P.md` and `0.md`…`6.md` exist on disk — no `0.1.md`.)

---

## 4. Additional execution defects found

| # | Defect | Where | Impact |
|---|--------|-------|--------|
| D1 | `$num`/`$Num` case collision | driver:472–473, 485, 493, 506 | Destroys issue-number registry → breaks linking, board fields, dependencies. **Primary failure.** |
| D2 | Stories missing `Level='story'` | driver:38 (data model) | All 22 stories fail to create. |
| D3 | No DryRun fidelity | driver DryRun branch skips issue creation/linking/fields/deps | The preview **did not and could not** catch D1/D2 — it gave false confidence. `ensure-issue.ps1` emits no number in DryRun, so the link/field/dep paths are never exercised. |
| D4 | No input schema validation | driver (pre-loop) | A pre-flight check for required keys (`Level`,`Title`,`Parent`) would have caught D2 instantly. |
| D5 | No verification step | driver (post-run) | The run reported "DONE" intent but never queried the repo to confirm counts matched; the discrepancy was only spotted manually. |
| D6 | **Skill bug** — strict-mode crash | `…/scripts/create-milestones.ps1:158` | Read `$_.reason` on a hashtable lacking that key while `Set-StrictMode -Latest` (from dot-sourced `common-auth.ps1`) was active → crash on *both* DryRun and Apply. **Fixed during the run** (guarded with `ContainsKey`). |

---

## 5. Skill-level weaknesses & misses (`gh-issue-tracking-init`)

1. **No reference orchestrator.** The skill ships six excellent, individually-idempotent op scripts but **no driver or manifest format**. The agent must hand-author a ~500-line orchestrator — exactly where every defect above occurred. A small reference driver (or a declarative `hierarchy.json` the skill consumes) would eliminate the D1/D2/D4 class of bugs. **Highest-leverage improvement.**
2. **Cross-script state leakage.** The op scripts are designed to be `&`-composed in one process, but `common.ps1`/`common-auth.ps1` set `Set-StrictMode -Latest` and `$ErrorActionPreference='Stop'` **globally and persistently**. Scripts that don't dot-source `common.ps1` (`create-milestones.ps1`, `import-labels.ps1`) inherit that state unpredictably once any sibling has run (D6). The skill should either make every op script strict-mode-safe or document that each must run in its own `pwsh -File` child process.
3. **DryRun cannot validate the pipeline.** `ensure-issue.ps1` returns no number in DryRun, so DryRun can only preview *issue creation intent* — never linking, board fields, or dependencies. The skill's "Always do a DryRun pass first" step therefore gives **false confidence** that the full run will work. Recommend a DryRun mode that simulates numbers (e.g. a local monotonic counter) so the entire graph can be dry-run.
4. **Stale self-containment docs.** The skill README (and the `common-auth.ps1`/`create-milestones.ps1`/`import-labels.ps1` header comments) claim all three are "also kept at the repository root." In reality root `scripts/` contains only `common-auth.ps1` and `import-labels.ps1` — **`create-milestones.ps1` does not exist at root.** Doc should be corrected.
5. **No `defect` template/label** and no current-issue-selection step — both explicitly out of scope per the plan, but worth tracking as follow-ups.

---

## 6. Driver / design weaknesses (the orchestrator)

- **Variable naming** allowed the case collision (D1). Use distinct names (`$issueNum` vs `$NumberByKey`).
- **Not transactional / not resumable.** A mid-run failure left 8 issues in the repo with no hierarchy/board state. The op scripts are idempotent, so a corrected re-run *will* recover, but the driver should checkpoint created numbers so a partial run can resume cleanly.
- **DryRun ≠ Apply shape** (D3). The DryRun path should mirror the exact body-generation + linking + field logic (with simulated numbers), not a divergent summary.
- **Silent acceptance of partial data.** No assertion that `Level`/`Title`/`Parent` exist per node before acting (D4).
- **No post-condition checks** (D5). After apply, verify: issue count == expected, every parent has the expected sub-issues, board item count == issue count, dependency count == edge count.

---

## 7. Plan-mapping review (decisions taken — for the record)

These were applied/validated during DryRun and are sound, but noted for completeness:

- **Mapping:** Phase → Epic (7), `T-x.y` → Story (22). Preserves the plan's own numbering for stable re-runs. The 4th level (Task) is intentionally unused; acceptance criteria live as in-issue checklists (allowed by the skill). ✅
- **Milestones = the 7 phases** (faithful 1:1, no invented groupings). ✅
- **`Phase` field intentionally omitted** — milestones + "By Epic" board view cover phase grouping. ⚠️ Note: the skill's auto-printed "By Phase" view requires a Phase field; since we skipped it, the relayed manual view list should drop "By Phase" in favor of "By Epic".
- **"All prior" dependencies** (T-6.1, T-6.3) were *interpreted* as blocked-by `4.1, 5.4, 3.4` (terminal tasks of the three parallel tracks at Gate 3). This is an inference, not literal — flag for confirmation. Minor.
- **Estimates unset** (the plan gives none). ✅

---

## 8. Severity-rated findings

| Sev | Finding |
|-----|---------|
| 🔴 Critical | D1 — `$num`/`$Num` case collision prevents recording issue numbers → breaks links/fields/deps (the root of Problem 1). |
| 🔴 Critical | D2 — stories lack `Level` → no stories created (Problem 2). |
| 🟠 High | D3 — DryRun gave false confidence; does not exercise link/field/dep paths. |
| 🟠 High | Skill — no reference orchestrator/manifest; all defects originated in the hand-written driver. |
| 🟡 Medium | D6 — `create-milestones.ps1` strict-mode crash (now fixed in-repo). |
| 🟡 Medium | Skill — global strict-mode/error-preference leaks across composed in-process script calls. |
| 🟡 Medium | D5 — no post-run verification; partial state went unnoticed. |
| 🟢 Low | D4 — no pre-flight schema validation of node data. |
| 🟢 Low | Skill — stale README re: root-copy of `create-milestones.ps1`. |
| 🟢 Low | Mapping — "All prior" dependency inference for T-6.1/T-6.3 needs confirmation. |

---

## 9. Recommended next steps

**Recover the hierarchy (corrected re-run):**
1. In `/tmp/kilo/gh-init-driver.ps1`:
   - Add `Level='story'` to every story node (fixes D2).
   - Rename the registry `$Num` → `$NumberByKey`, and the per-issue capture `$num` → `$issueNum` (fixes D1).
   - Add a pre-loop schema check (D4) and a post-run verification block (D5).
   - Make the DryRun path exercise body generation + simulated numbers so it previews the *whole* pipeline (D3).
2. Re-run. The op scripts are idempotent: the existing 8 issues will be matched by update (no duplicates), the 22 stories created, and the missing links/board fields/dependencies applied.
3. Confirm: 30 issues, Plan has 7 sub-issues, each epic has its stories nested, board has 30 items, 32 dependencies.

**Harden the skill:**
4. Add a reference driver (or a `hierarchy.json` manifest + loader) so callers compose data instead of writing an orchestrator.
5. Make every op script strict-mode-safe (guard optional properties) **or** document that each must run in its own `pwsh -File` child process.
6. Implement a number-simulating DryRun so linking/fields/deps can be previewed.
7. Correct the README's stale "kept at repository root" claim for `create-milestones.ps1`.

**Manual UI (unchanged, after a successful re-run):** add Project views (By Epic, By Status, Current work) and ensure the `Status` field has `In Review` / `Blocked` options.

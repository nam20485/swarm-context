# Handoff — two upstream defects to correct

**From:** run of `/gh-issue-tracking-init` against `intel-agency/gap-miner-v2-india89` (Project #92, 2026-07-20)
**Audience:** upstream dev team (maintainers of the canonical template + the `gh-issue-tracking-init` skill)
**Scope:** two defects found during the india89 seeding run, plus a clean scan of the run log, working copy, and GitHub assets.

---

## 1. AGENTS.md `## Repository identity` mislabels every clone as "the upstream template"

### Symptom
`AGENTS.md:5` reads:

> This repository — **`intel-agency/gap-miner-v2-india89`** — is the **upstream GitHub template**: it is cloned to seed each downstream instance …

This is **wrong for this repo**: `gap-miner-v2-india89` is a **downstream clone instance**, not the template.

### Evidence (this is template-wide, not india89-specific)
The same self-referential text appears in **every** clone with only the repo *name* substituted. Confirmed against a sibling:

> `gap-miner-v2-delta12` `AGENTS.md:5`: "This repository — **`intel-agency/gap-miner-v2-delta12`** — is the **upstream GitHub template** …"

All 14 `gap-miner-v2-*` repos carry the same `-<codename>` suffix, so none of them is the unsuffixed canonical template. The clone-creation replacement substitutes the repo **name** but leaves the **role label** (`upstream GitHub template`) intact — classic Class-2 template-self-referential contamination (the very failure mode documented in `docs/plans/template-content-strategy-plan.md` / the "Template vs. clone content strategy" memory entry, work item **W1**).

### Impact
Agents reading AGENTS.md misidentify a clone as the template, which can mis-target delegation, repo selection, and "treat any other repo as a clone" routing logic.

### Recommended fix (upstream template repo)
1. Make the identity section **non-self-referential** — derive the role at runtime instead of hardcoding prose. Prefer a sentinel such as `gh repo view --json isTemplate -q .isTemplate` (or an explicit `.agents/template-flag` marker) and render the identity line from that, so clones never inherit a stale "I am the template" claim.
2. Add the **post-clone reset step (W1)** to the clone-creation flow so the identity (and any other Class-2 state) is corrected when a new repo is seeded.

### Reconcile (upstream to confirm)
Several of this repo's own plan docs (`docs/plans/.completed/gap-miner-v2-india89-fix-plan.md`, `create-repo-from-slug.ps1 -TemplateRepoName "gap-miner-v2-india89"`, `docs/plans/.completed/gh-issue-tracking-plan-source-resolution.md:114`) **also** assert that india89 is the template / use it as the seeding source. That contradicts the clone evidence above. The upstream team should confirm which repo is the true canonical template and align these references.

---

## 2. `set-project-fields.ps1` emits a spurious `Field 'Phase' not found` warning on every call

### Symptom
Every `set-project-fields.ps1` invocation prints:

```
WARNING: Field 'Phase' not found on project; skipping.
```

even when **`-Phase` is never passed**. Observed 30× during the india89 run (once per issue). Harmless to output (Level/Priority/Status all set correctly) but noisy and a latent bug.

### Root cause
`scripts/set-project-fields.ps1` lines 92–96 build the single-select set with a `$null -ne $X` guard:

```pwsh
$singleSelect = [ordered]@{}
if ($null -ne $Level)    { $singleSelect['Level'] = $Level }
if ($null -ne $Priority) { $singleSelect['Priority'] = $Priority }
if ($null -ne $Phase)    { $singleSelect['Phase'] = $Phase }   # <-- fires even when omitted
if ($null -ne $Status)   { $singleSelect['Status'] = $Status }
```

In PowerShell, an **unbound `[string]` parameter is `""` (empty string), not `$null`**. Repro confirms:

- `Phase is in PSBoundParameters? False`
- `$null -eq $Phase` → **False**   (so `$null -ne $Phase` → **True**)

So `Phase=''` is wrongly added to `$singleSelect`; `Set-SingleSelect -FieldName 'Phase' -OptionName ''` then finds no `Phase` field and warns. The same latent flaw affects `Level`/`Priority`/`Status` whenever any of them is omitted (they'd warn `Option '' not found`).

### Fix (one-line pattern change)
Use `ContainsKey`, exactly as the script already does for `Estimate` on line 97 (`$hasEstimate = $PSBoundParameters.ContainsKey('Estimate')`):

```pwsh
$singleSelect = [ordered]@{}
if ($PSBoundParameters.ContainsKey('Level'))    { $singleSelect['Level'] = $Level }
if ($PSBoundParameters.ContainsKey('Priority')) { $singleSelect['Priority'] = $Priority }
if ($PSBoundParameters.ContainsKey('Phase'))    { $singleSelect['Phase'] = $Phase }
if ($PSBoundParameters.ContainsKey('Status'))   { $singleSelect['Status'] = $Status }
```

A Pester case should be added: splat without `-Phase` and assert no `Phase` entry and no warning.

---

## 3. Scan results — run log, working copy, GitHub assets

| Source | Result |
|---|---|
| **Forensic log** (`gh-init-gap-miner-v2-india89-20260720T184908Z.log`, 1243 lines) | Clean. `0` ERR / FAIL / exception lines. All OK / SKIP / STEP. |
| **apply-run.log** | Only anomaly is the recurring Phase warning (issue 2). No rate-limit, 403/422/500, or secondary-rate hits. |
| **Working copy** | `git status` shows only `.agents/memory.md` modified (intentional). Forensic log is gitignored (`gh-init-*.log`); driver + bodies isolated under `/tmp/kilo/gap-miner-v2-india89/`. No stray files. |
| **GitHub assets (Project #92)** | Verified clean: 30 issues (#1 plan + 7 epics + 22 stories); Plan #1 → 7 epic sub-issues; epics → 3/4/3/4/1/4/3 stories; 29 parent/child links; **33** blocked-by edges; board = 30 items, **all with Level + Priority + Status = Todo** (0 missing); 4 milestones; 16 canonical labels. No body/field defects. |

**No other issues found.** The only two actionable items are the AGENTS.md identity mislabel (§1) and the Phase-warning bug (§2).

---

## Recommended upstream actions

- [ ] **§1** Make `AGENTS.md` identity non-self-referential (runtime-detected role) and add the W1 post-clone reset step.
- [ ] **§1** Reconcile which repo is the canonical template (india89's plan docs reference it as `TemplateRepoName`, contradicting the clone evidence).
- [ ] **§2** Patch `set-project-fields.ps1` single-select guards to `$PSBoundParameters.ContainsKey(...)` + add a Pester case.

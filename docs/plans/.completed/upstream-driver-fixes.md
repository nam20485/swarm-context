# Upstream Fixes — gh-issue-tracking-init Driver Composition

**Origin:** `gap-miner-v2-charlie53` (downstream clone) · **Run date:** 2026-07-18
**Target:** the parent `gh-issue-tracking-init` skill (`.agents/skills/gh-issue-tracking-init/`)
**Purpose:** propagate the fixes below into the parent template so new clones don't repeat the same failure modes.

> These findings came from composing a single PowerShell orchestration driver for a 30-issue
> hierarchy (`Plan → 7 Epics → 22 Stories`) on `intel-agency/gap-miner-v2-charlie53`. One is a
> genuine **skill-script contract defect**; the rest are **driver-author pitfalls the skill should
> structurally prevent**. Each has a ready-to-apply patch.

---

## TL;DR

| ID | Severity | Type | One-line fix |
|----|----------|------|--------------|
| F1 | **High** | Skill code defect | `ensure-project.ps1` must `Write-Output` the project number so a driver can capture it (today it only `Write-Host`s it). |
| F2 | Medium | Skill guidance gap | Warn driver-authors: **integer-keyed `[ordered]@{}`/`@{}` lookups are unreliable** in PowerShell — use `switch` functions or string keys. |
| F3 | Medium | Skill guidance gap | Specify the node-hashtable **mandatory schema** + a **DryRun self-check** so an omitted field (e.g. `Name`) fails loudly instead of producing empty titles. |
| F4 | Info | Verify upstream | `common.ps1` `[long]` cast + REST `Find-IssueNumberByTitle` are fixed in this clone; **confirm the parent has them**. |

---

## F1 — `ensure-project.ps1` does not emit the project number to stdout *(High, code defect)*

### Symptom
A composing driver cannot capture the project number programmatically:

```pwsh
$Proj = & "$Skill/ensure-project.ps1" -Owner $Owner -Repo $Repo -Title $Title   # $Proj is $null
```

### Root cause
`ensure-project.ps1` only ever prints the project number via `Write-Ok` / `Write-Skip`, which write
to the **host** (console), not the **success stream** (stdout pipeline). So `$()` capture yields
nothing. This contradicts the sibling contract: `ensure-issue.ps1` *does* `Write-Output` its issue
number (line 112 / 140) precisely so callers can capture it.

References in this clone:
- `ensure-project.ps1:106` — `Write-Ok "Created project #$projectNumber ..."` (host only)
- `ensure-project.ps1:96`  — `Write-Skip "Project ... already exists (#$projectNumber)."` (host only)
- `SKILL.md:64` — "Record the printed **project number**" (implies manual reading, not capture)

### Workaround used in the run
Re-query by title after creation:

```pwsh
$Proj = (gh project list --owner $Owner --format json --limit 200 | ConvertFrom-Json |
         Where-Object { $_.title -eq $Title }).number
```

### Recommended upstream fix (apply to `ensure-project.ps1`)
Emit the number on stdout, mirroring `ensure-issue.ps1`. Insert just **before the "Views" block**
(currently `ensure-project.ps1:163`, the `Write-Host ''` line):

```pwsh
# --- Emit project number on stdout so composing drivers can capture it via $() ---
# (Host-stream Write-* above are human-readable status; this is the machine-readable contract,
#  matching ensure-issue.ps1 which Write-Outputs its issue number.)
if ($null -ne $projectNumber) {
    Write-Output $projectNumber
}
```

In `-DryRun` `$projectNumber` is `$null` (project not created), so nothing is emitted — drivers must
treat a `$null` result as "DryRun; re-query/not-applicable", which is the correct behavior.

### Companion doc fixes
- `SKILL.md:64` — change step 4 to: *"Capture the printed **project number** from stdout
  (`$Proj = & ensure-project.ps1 ...`); in `-DryRun` it is `$null`."*
- `scripts/README.md` operation table — note `ensure-project.ps1` **prints the project number to
  stdout** in its "Key parameters" / contract column.

---

## F2 — Integer-keyed `[ordered]@{}`/`@{}` lookups are unreliable in PowerShell *(Medium, guidance gap)*

### Symptom
In the DryRun, epics/stories 1–6 resolved their milestone correctly, but **epic 7 and stories 7.x
showed an empty milestone** (`milestone:  |`).

### Reproduction (isolated, copy-paste verbatim)
```pwsh
$m = [ordered]@{ 1='G1'; 2='G1'; 3='G2'; 4='G2'; 5='G3'; 6='G3'; 7='G3' }
$m[7]            # -> ''   (empty!)
$m['7']          # -> ''   (empty!)
$m[1]            # -> 'G1' (works)
$m.Count          # -> 7
$m.Keys           # -> 1 2 3 4 5 6 7  (all Int32, all present)
```
Keys 1–6 resolve; key **7 does not** — even though `.Values | Select-Object -Unique` correctly
yields `G3` (proving the value exists).

### Root cause
Observed unreliability of integer-keyed `[ordered]@{}` / `@{}` indexing in PowerShell 7.6 for some
keys. The exact internal mechanism was **not** fully determined; the behavior is reproducible and
silent (no error), which is what makes it dangerous in a driver.

### Fix used in the run (robust regardless of root cause)
Replace lookup dictionaries with **`switch` functions** (or string keys):

```pwsh
function Milestone-For {
    param([int]$N)
    switch ($N) {
        1 { 'Gate 1: Foundation' }
        2 { 'Gate 1: Foundation' }
        3 { 'Gate 2: Pipelines' }
        4 { 'Gate 2: Pipelines' }
        5 { 'Gate 3: Interface and Hardening' }
        6 { 'Gate 3: Interface and Hardening' }
        7 { 'Gate 3: Interface and Hardening' }
        default { throw "Unknown epic number for milestone: $N" }
    }
}
$Milestones = @('Gate 1: Foundation', 'Gate 2: Pipelines', 'Gate 3: Interface and Hardening')
```

### Recommended upstream fix
Add a new subsection to `SKILL.md` (after the "Delegation performance (batching)" block, ~line 112):

> ### Avoid integer-keyed lookup dictionaries in the driver
> PowerShell integer-keyed `[ordered]@{}` / `@{}` indexing is **unreliable for some keys** (silent
> empty returns; reproduced on PS 7.6). When composing a driver, **do not** build milestone/phase
> lookup maps as integer-keyed dictionaries. Prefer, in order:
> 1. a `switch` function (single source of truth, fails loudly on unknown keys), or
> 2. a `[string]`-keyed `@{}` accessed via `$map["7"]`.

---

## F3 — Driver node data must carry every display field; DryRun must self-check *(Medium, guidance gap)*

### Symptom
First DryRun rendered every story title as `Story 1.1:   |` (empty name), while epics rendered
correctly.

### Root cause
A **driver-author error**: the story node hashtables omitted the `Name=` key (epics included it, so
`$e.Name` worked but `$s.Name` was `$null`). The skill gives no canonical node schema and no DryRun
assertion, so the omission was silent until a human read the preview.

### Reproduction (proves the omission class, not a PS quirk)
```pwsh
$b = @{ Key='1.1'; Epic=1; Tid='T-0.1'; Area='area/infra'; Priority='P0'; Prereqs=@()
       Objective='...'; Scope=@('x'); PlanSteps=@('s'); AC=@('c'); Notes='n' }
$b.Contains('Name')   # -> False   (Name was never a key)
$b.Count               # -> 11
```

### Recommended upstream fix (two parts)

**1. Document the canonical node schema** — add to `SKILL.md` orchestration step 1 ("Parse the plan"):

> Each node must be a hashtable with at least these keys (assert presence before rendering):
> - `Level` (`plan`/`epic`/`story`/`task`), `Title` (the full numbered title) **or** the parts to
>   build it (`N`/`M`/`K`, `Name`),
> - `Labels`, `Milestone`, `Priority`, `Phase` (if used),
> - `BodyFile` (after rendering), `Prereqs` (array of sibling keys, story/task level).

**2. Mandate a DryRun self-check** — add to the batching section:

> ### DryRun must assert completeness
> Before printing the preview, assert every node renders a non-empty title and (for epics/stories)
> a non-empty milestone; throw on the first empty value so omissions fail loudly in preview rather
> than creating empty-titled issues on apply.

```pwsh
foreach ($n in $nodes) {
    if ([string]::IsNullOrWhiteSpace($n.Title)) { throw "Node missing title: $($n | ConvertTo-Json -Compress -Depth 2)" }
    if ($n.Level -in 'epic','story' -and [string]::IsNullOrWhiteSpace($n.Milestone)) { throw "Node $($n.Title) missing milestone" }
}
```

### Fix used in the run
Centralized display names in a `Story-Name` `switch` function (single source of truth), eliminating
per-node `Name` duplication and the `.Name` dependency entirely.

---

## F4 — Confirm two `common.ps1` fixes are present in the parent *(Info — already fixed locally)*

These are **already applied in this clone** (from the earlier `gap-miner-v2-oscar32` run, per
project memory) and were verified present during this run:

- `common.ps1:99-101` — `Get-IssueDbId` casts to **`[long]`**, not `[int]`. **Why it matters:**
  GitHub global issue database IDs now exceed `Int32.MaxValue` (2,147,483,647); an `[int]` cast
  throws and breaks **every** `link-sub-issue.ps1` and `set-dependency.ps1` call on modern repos.
- `common.ps1:110-134` — `Find-IssueNumberByTitle` resolves via the **paginated REST issues
  endpoint**, not `gh issue list --search` (which routes through the GraphQL Search API and fails
  under its separate, stricter rate limit). **Why it matters:** idempotent re-runs (`ensure-issue.ps1`
  title lookup) fall over on large repos otherwise.

**Action for the parent template:** confirm both are present; if missing, port them verbatim (they
are the most recent fixes in this clone's `common.ps1`).

---

## Upstream change checklist

| File | Action | Finding |
|------|--------|---------|
| `scripts/ensure-project.ps1` | Add `Write-Output $projectNumber` before the Views block (~line 163) | F1 |
| `scripts/README.md` | Note `ensure-project.ps1` emits project number to stdout | F1 |
| `SKILL.md` step 4 (~line 64) | "Capture project number from stdout; `$null` in DryRun" | F1 |
| `SKILL.md` batching section (~line 112) | Add "Avoid integer-keyed lookup dicts" subsection | F2 |
| `SKILL.md` step 1 / batching | Add canonical node schema + DryRun self-check subsection | F3 |
| `scripts/common.ps1` | **Verify** `[long]` cast (line 101) + REST `Find-IssueNumberByTitle` (line 110+) exist | F4 |
| `scripts/tests/` | Add Pester cases: (a) `ensure-project.ps1` emits number to stdout; (b) label/milestone op scripts still parse with the new emit | F1 |

---

## Recommended hardened driver skeleton (incorporates F1–F3)

```pwsh
# F2: switch-based lookups, never integer-keyed dicts
function Milestone-For { param([int]$N) { switch ($N) { 1{''} ... default { throw } } } }
function Story-Name     { param([string]$K) { switch ($K) { '1.1'{''} ... default { throw } } } }

# F3: canonical node schema (Title + Milestone mandatory for epic/story)
$nodes = @( ... )

# F3: DryRun self-check
foreach ($n in $nodes) {
    if ([string]::IsNullOrWhiteSpace($n.Title)) { throw "Node missing title" }
    if ($n.Level -in 'epic','story' -and [string]::IsNullOrWhiteSpace($n.Milestone)) {
        throw "Node $($n.Title) missing milestone"
    }
}

# F1: capture project number directly from stdout (no re-query needed once F1 is applied upstream)
$Proj = & "$Skill/ensure-project.ps1" -Owner $Owner -Repo $Repo -Title $ProjectTitle   # int in apply; $null in DryRun
if (-not $Proj -and -not $DryRun) { throw 'Project number not emitted by ensure-project.ps1' }
```

## Verification of the fixes in this run
- Second DryRun: all 30 titles, milestones, priorities, and areas correct; 29 sub-issue edges + 28
  dependency edges enumerated. No skill-script defects encountered beyond F1 (worked around via
  re-query).
- The full apply against `intel-agency/gap-miner-v2-charlie53` is pending user confirmation (see
  session); the driver and rendered bodies are on disk under `/tmp/kilo/gapminer-gh-init/`.

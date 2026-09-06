# gh-issue-tracking-init: Fix driver bugs & add trace logging

**Plan path:** `.kilo/plans/1784192093660-gh-issue-tracking-fix-trace.md`
**Repo:** `intel-agency/gap-miner-v2-oscar32` · **Project:** `#88`
**Driver:** `/tmp/kilo/gh-init-driver.ps1`
**Baseline:** `docs/plans/gh-issue-tracking/gh-issue-tracking-init-run-review.md`

## Goal

1. Fix the three critical driver bugs that caused the partial failure and cascading skips:
   - Variable name collision (`$num` vs `$Num`)
   - Missing `Level='story'` on story nodes
   - **Epic parent references are chained instead of pointing to Plan** (all epics should have `Parent='P'`, not `Parent='0'`, `Parent='1'`, etc.)
2. Add a persistent **trace log file** so every op-script call, args snapshot, exit, issue number, and failure is recoverable post-mortem.
3. Re-run against the repo to complete the remaining hierarchy: 22 stories, sub-issue links, board fields for all 30, 32 blocked-by edges.

## Current state (from review)

- ✅ 15 labels, 7 milestones (`Phase 0`–`Phase 6`), Project #88 + `Level`/`Priority`/`Estimate` fields.
- ✅ 8 issues exist (Plan `#1` + Epics `#2`–`#8`), correctly labeled, milestoned, bodied.
- ❌ 0/22 stories.
- ❌ 0 sub-issue links (Plan→Epics, Epics→Stories).
- ❌ 0 board items (`totalCount: 0`).
- ❌ 0/32 dependency edges.

The op scripts are idempotent, so a corrected re-run will reconcile existing issues and fill in the gaps without duplication.

## Scope

- **In scope:** fixes to `/tmp/kilo/gh-init-driver.ps1`; a trace-log file; a re-run; post-run verification.
- **Out of scope:** skill op-script rewrites (D6 is already fixed in `create-milestones.ps1:158`); Project view creation (GitHub limitation); deeper DryRun fidelity overhaul (deferred).

## Decisions

| # | Decision | Rationale |
|---|----------|-----------|
| D1 | Trace logging: **driver-only** (wrap op-script invocations) rather than adding trace to every op script. | Driver orchestrates every call; gives full visibility without modifying the (now-fixed) skill. Keeps trace logic in one place, easy to extend. |
| D2 | Trace file: **per-run** at `/tmp/kilo/gh-init-trace-<YYYYMMDD-HHMMSS>.log`. | Preserves history across re-runs; easy to locate next to the body files. |
| D3 | Trace format: `ISO-timestamp \| LEVEL \| component \| message`, plain text. | Greppable, readable, sortable by timestamp. Levels: `STEP`, `INFO`, `OK`, `WARN`, `ERR`, `DRY`. |
| D4 | Variable rename: `$num` → `$issueNum`; `$Num` → `$NumberByKey`. | Eliminates the PowerShell case-insensitive collision at the root cause. |
| D5 | Story Level fix: add `Level='story'` to every story node. | Root cause of all 22 "Body file not found" failures. |
| D6a | Epic parent fix: all 7 epics must have `Parent='P'`, not chained references. | Root cause of incorrect hierarchy — epics should be siblings under Plan, not nested through each other. Without this fix, Plan would only have Epic 0 as a sub-issue. |
| D6b | Pre-flight schema check before the creation loop. Required keys: `Level`, `Title`, `Parent` (except plan); stories additionally require `AC`. Fail-fast with a list of problems. | Cheap structural validation; would have caught the missing `Level='story'` immediately. |
| D7 | Post-run verification query block counting issues, sub-issues, board items, and deps, asserted against the expected totals. Trace-log pass/fail per check. | Prevents silent partial failures from going unnoticed. |
| D8 | Light DryRun parity upgrade: trace-log the body-generation step too, so DryRun catches missing fields / body-builder throws. | Captures the exact class of bug D5 was (missing Level → body never written) even in DryRun. Full simulated-number DryRun deferred to a future scope. |
| D9 | Dependencies: "All prior" for `T-6.1` / `T-6.3` → blocked by `{4.1, 5.4, 3.4}` (Gate-3 leaf tasks). | Inference documented and re-validated in the review. |

## Tasks (ordered)

### T1. Add trace-logging scaffolding
- Add a `Trace-Write` helper at the top of the orchestration block:

  ```powershell
  $TraceFile = Join-Path $BodyDir "gh-init-trace-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
  function Trace-Write($Level, $Component, $Message) {
      $line = "$(Get-Date -Format 'o') | $Level.PadRight(4) | $Component.PadRight(16) | $Message"
      $line | Add-Content -LiteralPath $TraceFile -Encoding utf8
      switch ($Level) {
          'ERR'   { Write-Host $line -ForegroundColor Red }
          'WARN'  { Write-Host $line -ForegroundColor Yellow }
          'OK'    { Write-Host $line -ForegroundColor Green }
          'DRY'   { Write-Host $line -ForegroundColor Yellow }
          default { Write-Host $line }
      }
  }
  ```
- Wrap `Invoke-ScriptWithTrace($scriptPath, $args)`: invoke the target, capture stdout, exit code, and duration; trace `OK` on success, `ERR` on failure with the tail of stdout on error. Use this wrapper for every op-script call (`ensure-labels`, `create-milestones`, `ensure-project`, `ensure-issue`, `link-sub-issue`, `set-project-fields`, `set-dependency`).
- Open trace file at start of orchestration; register a `trap` to flush a final `ERR` summary if the driver aborts.
- Print the trace file path once at the top and once at the end.

### T2. Fix the case-collision (D4 decision)
Replace every occurrence of `$Num` with `$NumberByKey` and `$num` with `$issueNum`:
- `$NumberByKey = @{}` (initialization).
- Capture line: `$issueNum = & …` (driver:472).
- Record line: `$NumberByKey[$n.Key] = [int]$issueNum` (driver:473).
- Link: `ParentNumber $NumberByKey[$n.Parent] -ChildNumber $NumberByKey[$n.Key]` (driver:485).
- Board fields: `-IssueNumber $NumberByKey[$n.Key]` (driver:493).
- Dependencies: `-IssueNumber $NumberByKey[$n.Key] -BlockedByNumber $NumberByKey[$p]` (driver:506).
- Final summary loop at the end: use `$NumberByKey`.

### T3a. Fix epic parent hierarchy (critical bug #3)
In the `$Epics` array (driver lines 26-32), change all `Parent` values to `'P'`:
- Current (WRONG): Epic 0→P, Epic 1→0, Epic 2→1, Epic 3→2, Epic 4→3, Epic 5→4, Epic 6→5 (creates a chain)
- Correct: Epic 0→P, Epic 1→P, Epic 2→P, Epic 3→P, Epic 4→P, Epic 5→P, Epic 6→P (all epics are direct children of Plan)

This ensures Plan #1 has all 7 epics as sub-issues (not just Epic 0).

### T3b. Fix missing story Level (D5 decision)
Add `Level='story'` to **all 22 story hashtable literals** so `switch ($n.Level) { 'story' {…} }` matches and `Set-Content` writes each body. The plan and epics already have `Level` set explicitly.

### T4. Pre-flight schema check (D6 decision)
Before the creation loop, iterate `$Ordered` and verify:
- every node has `Level` ∈ `plan|epic|story|task`;
- every node has a non-empty `Title` starting with `Plan:` / `Epic <n>:` / `Story <n>.<m>:`;
- every non-plan node has `Parent` that exists as a key in `$Ordered`;
- every story has a non-empty `AC` array.
Fail with a bulleted list of problems and trace-log each violation as `ERR schema | <node> missing <field>`. Only proceed if zero violations.

### T5. Instrument creation / linking / fields / dependencies with trace
For each stage (labels, milestones, project, issues, links, fields, deps):
- Trace `STEP` before the stage with expected counts.
- For each op-script call use `Invoke-ScriptWithTrace`; capture stdout (including the printed issue/dep numbers) so the trace file is a complete record of what happened.
- On `ERR` (any throw), log and continue (idempotent re-runs recover).

### T6. Light DryRun parity upgrade (D8 decision)
In DryRun, still generate bodies (Set-Content already runs in DryRun today) and **trace-log** any body-builder exception or schema violation. This catches missing-field errors (like D5) even without issuing gh API calls.

### T7. Post-run verification (D7 decision)
After the apply loop, run:
```powershell
function Verify-State {
    $issuesByTitle = gh issue list --repo $Repo --state all --json number,title --limit 100 | ConvertFrom-Json
    $created = @{}; foreach ($n in $Ordered) {
        $match = $issuesByTitle | Where-Object { $_.title -eq $n.Title } | Select-Object -First 1
        $created[$n.Key] = $match.number
    }
    $subCount = 0; foreach ($parent in ($Ordered | Where-Object Level -in 'plan','epic')) {
        $n = ($created[$parent.Key]); if (-not $n) { continue }
        $children = gh api "repos/$Repo/issues/$n/sub_issues" --jq 'length'
        $expected = @($Ordered | Where-Object Parent -eq $parent.Key).Count
        Trace-Write INFO verify "parent $($parent.Title) sub_issues=$children expected=$expected"
        $subCount += [int]$children
    }
    $itemsJson = gh project item-list $ProjectNumber --owner $Owner --format json | ConvertFrom-Json
    Trace-Write INFO verify "board items=$($itemsJson.totalCount) expected=$($Ordered.Count)"
    # deps: sum via gh api per issue → blocked_by[].length
    $depCount = 0; foreach ($s in $Stories) {
        $n = $created[$s.Key]; if (-not $n) { continue }
        $depCount += [int](gh api "repos/$Repo/issues/$n/dependencies/blocked_by" --jq 'length')
    }
    Trace-Write INFO verify "dep edges=$depCount expected=32"
}
```
Trace `OK verify` if every expected matches, `ERR verify` for each mismatch. Console surfaces the summary.

### T8. Re-run DryRun, then Apply
- Run the fixed driver with `-DryRun`. Confirm: schema check passes; trace file shows 30 bodies generated; 30 "would create" entries; 29 "would link" entries; 30 "would set fields" entries; 32 "would set dep" entries; zero `ERR`.
- Run the fixed driver in Apply. Expected:
  - 8 existing issues updated (idempotent).
  - 22 stories created with bodies.
  - 7 Plan→Epic and 22 Epic→Story sub-issue links recorded.
  - 30 board items with `Level`, `Priority`, `Status=Todo` set.
  - 32 blocked-by edges recorded (600ms sleep between to avoid rate limit).
- Print the final trace file location and verification summary.

## Validation

### Local (after each DryRun / Apply)
- `grep ERR /tmp/kilo/gh-init-trace-*.log` returns only the `ERR verify` lines from prior (broken) runs; the latest trace file has zero `ERR` lines.
- Console shows `verify: all counts match`.

### Against GitHub (after Apply)
- `gh issue list --repo $Repo --state all --limit 100 --json title | jq 'length'` → **30**.
- `gh api repos/$Repo/issues/1/sub_issues --jq 'length'` → **7** (the 7 epics).
- For each epic `#2..#8`, `sub_issues` length matches that epic's story count.
- `gh project item-list 88 --owner intel-agency --format json --jq '.totalCount'` → **30**.
- `gh api repos/$Repo/issues/<story>/dependencies/blocked_by --jq 'length'` sums to **32**.

### Idempotency
Re-running Apply a second time should produce a trace file where every op reports "skipped"/"matched" and zero actual mutations occur.

## Risks

| Risk | Mitigation |
|------|-----------|
| Secondary rate limit on 32 `set-dependency` POSTs. | 600ms sleep between dep calls (already in driver). |
| `ensure-project.ps1` field-create order or option casing changes. | Trace-captures stdout from field-list; verification compares fields by name. |
| Story bodies fail to write again due to encoding edge case. | Trace-logs each `Set-Content` result; schema check catches missing AC before write. |
| "By Phase" view suggestion is stale. | The relay-to-user step drops "By Phase" (Phase field omitted) and keeps "By Epic", "By Status", "Current work". |

## Out of scope / deferred

- Full DryRun graph simulation with dummy issue numbers (D3 in review) — future pass.
- Skill-level hardening: per-script strict-mode safety audit, reference orchestrator / `hierarchy.json` manifest.
- Project views (GitHub CLI limitation).
- `defect` template/label; current-issue-selection workflow (skill's out-of-scope).

## Open questions

None — the trace-logging design (driver-only, per-run file, structured text) is the obvious default and can be overridden on reply.

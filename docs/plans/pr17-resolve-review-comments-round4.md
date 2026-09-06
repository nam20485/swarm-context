# PR #17 Review Comment Resolution Plan — Round 4

Date: 2026-08-18
PR: [#17](https://github.com/intel-agency/agent-context/pull/17) — Refactor dry-run handling, update permissions, and clean up docs
Head: `d4896e7` (branch `development`)
Unresolved threads: 10

## Summary

This plan addresses the 10 remaining unresolved review threads on PR #17. The threads fall into four categories:

- **Skill completeness** (threads 1, 2, 10): the `update-powershell-standard` skill shipped without its `SKILL.md`, without tests, and the plan doc references a wrong path.
- **Dry-run regression test** (thread 3): the core behavioral fix has no test asserting zero API calls under `-DryRun`.
- **Security hardening** (thread 9): orchestrator bash redirect-write surface. ~~Thread 8 (symlink/junction path-escape guard) — skipped per maintainer decision.~~
- **Cleanup & accuracy** (threads 4, 5, 6, 7): dead config, missing timeout, memory nits, and bash allow-list scoping.

## Thread inventory

| # | Thread ID | Severity | File | Author | Summary | Action |
|---|-----------|----------|------|--------|---------|--------|
| 1 | `r3801982092` | P2 | `update-powershell-standard.ps1:1` | nam20485 | Missing `SKILL.md` for skill | **Add** `SKILL.md` |
| 2 | `r3801982097` | P2 | `update-powershell-standard.ps1:55` | nam20485 | No Pester tests for 386-line script | **Add** tests + register in `validation.ps1` |
| 3 | `r3801982107` | P2 | `link-sub-issue.ps1:53` | nam20485 | Dry-run zero-API-call regression test missing | **Add** assertions to existing DryRun tests |
| 4 | `r3801982114` | P3 | `opencode.jsonc:156` | nam20485 | ~55 lines dead commented-out config | **Delete** commented blocks |
| 5 | `r3801982123` | P3 | `update-powershell-standard.ps1:225` | nam20485 | `Invoke-WebRequest` has no `-TimeoutSec` | **Add** `-TimeoutSec 60` |
| 6 | `r3801982130` | P3 | `memory.md:26` | nam20485 | "Not yet implemented" partially stale; commit title misleading | **Update** memory entry |
| 7 | `r3801982139` | P3 | `orchestrator.md:58` | nam20485 | `git branch*`/`git remote*` admit mutating forms | **Add** deny entries for destructive forms |
| 8 | `r3802010516` | P2/security | `update-powershell-standard.ps1:355` | factory-droid | Path-escape writes via symlinks/junctions | **Skip** — will not fix (see Thread 8 below) |
| 9 | `r3802010522` | P1/security | `orchestrator.md:47` | factory-droid | Bash redirect can still write files (`cat > out`) | **Keep all** with explicit decision note (will not fix) |
| 10 | `r3802010527` | P2 | `powershell-standard-rules-plan.md:74` | factory-droid | Plan doc points to wrong script path | **Fix** path reference |

## Detailed actions

### Thread 1 — Add `SKILL.md` for `update-powershell-standard`

**File:** `.agents/skills/update-powershell-standard/SKILL.md` (new file)

Create an AgentSkills-spec-compliant `SKILL.md` with YAML frontmatter (`name: update-powershell-standard`, `description`) and the standard sections: triggers (when to invoke), decision guidance (version comparison, what gets regenerated), and the call site invoking `scripts/update-powershell-standard.ps1`. The skill body stays under 500 lines per progressive-disclosure rules.

**Acceptance:** `skills-ref validate .agents/skills/update-powershell-standard` passes.

### Thread 2 — Add Pester tests for `update-powershell-standard.ps1`

**File:** `.agents/skills/update-powershell-standard/scripts/tests/UpdatePowershellStandard.Tests.ps1` (new file)

Test cases using `-SourceFile` fixtures (no network access):

1. **Unmapped section fails loudly** — upstream with an unexpected `## ` heading triggers the missing-key guard.
2. **Fence-aware splitting** — code fences (` ``` `) inside sections are not mistaken for section boundaries.
3. **Write-only-on-change** — running twice with the same fixture writes files on the first run and reports them unchanged on the second.
4. **`-CheckOnly` reports without writing** — no files created under `RepoRoot`.
5. **`-Force` re-splits even on same version** — files written when version matches but `-Force` is given.
6. **Version stamping** — the index's `**Upstream version:** x.y.z` line is updated to the fixture's version.
7. **Missing index warning** — emits a warning and does not throw when the index file is absent.
8. **Empty upstream throws** — empty `-SourceFile` content raises a terminating error.
9. **Preamble placement** — preamble content (before first `## `) lands only in `00-non-negotiables.md`.

**File:** `validation.ps1` — add `.agents/skills/update-powershell-standard/scripts` to the PSScriptAnalyzer scan path and the Pester coverage path.

**Acceptance:** `Invoke-Pester -Path .agents/skills/update-powershell-standard/scripts/tests -Output Detailed` passes; coverage > 85% on the script.

### Thread 3 — Dry-run zero-API-call regression test

**File:** `.agents/skills/gh-issue-tracking-init/scripts/tests/MilestonesAndLinks.Tests.ps1`

In the existing `DryRun path` contexts for both `link-sub-issue.ps1` and `set-dependency.ps1`:

1. Add `$global:GhCalls = @()` to `BeforeEach` and a recording `global:gh` stub (same pattern as the "actual linking" context).
2. Add assertion: `$global:GhCalls | Should -HaveCount 0` to the DryRun `It` block — proving zero API calls are made.
3. Rename the `It` descriptions from "child not already linked" / "not already blocked" to "makes zero API calls and reports the planned action" (dry-run skips discovery entirely).

**Acceptance:** The two DryRun `It` blocks assert both message text and zero `gh` API calls.

### Thread 4 — Delete dead commented-out config

**File:** `.opencode/opencode.jsonc`

Delete:
- Line 10: `// "small_model": "cline-pass/deepseek-v4-flash",`
- Lines 156–208: the entire commented-out alternate `qwencloud` model definitions block

**Acceptance:** No commented-out config remains in the file; JSONC still parses cleanly.

### Thread 5 — Add `-TimeoutSec` to `Invoke-WebRequest`

**File:** `.agents/skills/update-powershell-standard/scripts/update-powershell-standard.ps1`

Change line 225 from:
```powershell
$response = Invoke-WebRequest -Uri $SourceUrl
```
to:
```powershell
$response = Invoke-WebRequest -Uri $SourceUrl -TimeoutSec 60
```

**Acceptance:** A hung upstream produces a clear timeout error within 60 seconds.

### Thread 6 — Fix memory.md accuracy nits

**File:** `.agents/memory.md`

Two corrections to the PowerShell Engineer Standard entry (around line 26):

1. Change "Not yet implemented" language to reflect that the refresh script landed as a partial plan step 1 (commit `d253687`), while steps 2–7 (index, subagent definitions, AGENTS.md/delegation updates, house overrides, validation, cleanup) remain.
2. Correct the commit `a84e5e1` description — the commit title mentions "and subagent definition" but no subagent definition files exist in this PR (`.kilo/agent/` doesn't exist yet). Update to reflect what actually landed.

**Acceptance:** Memory accurately describes the current state of the PowerShell Standard implementation.

### Thread 7 — Scope `git branch*`/`git remote*` to deny mutating forms

**File:** `.opencode/agents/orchestrator.md`

Add explicit deny entries (following the same pattern as the existing `find`/`echo` denies):

```yaml
    "git branch -D*": deny    # force-delete branches — not read-only coordination
    "git branch -d*": deny    # delete branches — not read-only coordination
    "git remote remove*": deny  # remove remotes — not read-only coordination
    "git remote set-url*": deny # mutate remote URLs — not read-only coordination
```

These go between the existing `git branch*`: allow and the `gh pr*` lines, in the deny section.

**Acceptance:** Orchestrator frontmatter has explicit deny entries for the four mutating forms.

### Thread 8 — Block path-escape writes via symlinks/junctions — SKIPPED

**Decision: will not fix.**

The symlink/junction path-escape guard is too defensive for a script that writes to `.agents/rules/powershell/` inside a repo the user already controls. A crafted checkout that plants a symlink under that path requires the attacker to already have write access to the repo — at which point they can edit files directly without needing a redirect through `Set-Content`. The guard adds complexity to a straightforward file-writing loop for negligible security gain.

**Reply to thread:** No code change. The script writes to `.agents/rules/powershell/` under `$RepoRoot`, and a crafted checkout that plants a reparse point at that location already implies write access to the repo (the attacker could edit files directly). The added complexity of a `Resolve-Path` + `ReparsePoint` check in the write loop is not justified by the threat model.

### Thread 9 — Keep all output-producing commands with explicit decision note

**File:** `.opencode/agents/orchestrator.md`

**Decision: will not fix.** No commands are removed from the allow-list.

The redirect-write risk (`command > file` bypassing `edit: deny`) is uniform across all output-producing commands — `rg`, `cat`, `head`, `tail`, `tree`, `jq`, `wc` can all redirect output to files. Removing one while keeping six others would be arbitrary security theater. The glob-based permission system cannot parse shell syntax to distinguish reads from redirect-writes without breaking legitimate commands (`2>&1`, `--format` strings). The orchestrator is a trusted agent operating under explicit prose guardrails ("You implement nothing", "delegate all mutations"). Removing these commands would force delegation to a subagent for routine monitoring (watching CI runs, reading logs with `head`/`tail`, inspecting files with `cat`/`rg`), losing visibility into the orchestrator's tool calls and relayed output.

**Action:** Add an explicit decision note as a YAML comment block above the output-producing commands in the allow-list:

```yaml
    # --- Kept intentionally (redirect-write risk accepted) ---
    # These produce output useful for live monitoring and log inspection,
    # which the orchestrator routinely performs (watching CI runs, reading
    # subagent progress, inspecting files inline). Shell redirection
    # (command > file) can technically bypass edit:deny, but: (a) the
    # orchestrator is a trusted agent operating under explicit prose
    # guardrails ("You implement nothing"), (b) the glob-based permission
    # system cannot parse shell syntax to distinguish reads from
    # redirect-writes without breaking legitimate commands (2>&1, --format
    # strings), and (c) removing these would force delegation to a
    # subagent for routine monitoring, losing visibility into the
    # orchestrator's tool calls and relayed output.
```

**Acceptance:** All output-producing commands carry an explicit decision note in the frontmatter. Thread reply explains the rationale (will not fix).

### Thread 10 — Fix script path in plan doc

**File:** `docs/plans/powershell-standard-rules-plan.md`

Change line 74 from:
```
`scripts/update-powershell-standard.ps1`
```
to:
```
`.agents/skills/update-powershell-standard/scripts/update-powershell-standard.ps1`
```

Also update the "Proposed addition" section (line 186) to match:
```
`scripts/update-powershell-standard.ps1`
```
→ `.agents/skills/update-powershell-standard/scripts/update-powershell-standard.ps1`

**Acceptance:** All path references in the plan doc point to the actual skill-script location.

## Execution order


1. **Quick wins first** (threads 4, 5, 10): trivial edits, no tests to validate.
2. **Security & permissions** (threads 7, 9): orchestrator frontmatter — deny mutating git forms, add decision note for output-producing commands.
3. **Skill completeness** (thread 1): author `SKILL.md`.
4. **Tests** (threads 2, 3): write Pester tests, update `validation.ps1`, run the suite.
5. **Memory cleanup** (thread 6): update memory last (after all changes are made, so the entry reflects the final state).
6. **Commit, push, reply to all threads (including thread 8 "will not fix"), resolve, and verify 0 unresolved.**

## Validation checklist

- [ ] Pester suite passes: `Invoke-Pester -Path .agents/skills/gh-issue-tracking-init/scripts/tests -Output Detailed`
- [ ] New Pester suite passes: `Invoke-Pester -Path .agents/skills/update-powershell-standard/scripts/tests -Output Detailed`
- [ ] Coverage > 85% on `update-powershell-standard.ps1`
- [ ] `opencode.jsonc` parses as valid JSONC
- [ ] Orchestrator YAML frontmatter parses without duplicate keys
- [ ] Decision note comment block present above output-producing commands in orchestrator frontmatter
- [ ] Markdownlint clean on all modified `.md` files
- [ ] `skills-ref validate .agents/skills/update-powershell-standard` passes
- [ ] After resolving all threads: re-fetch shows 0 unresolved review threads

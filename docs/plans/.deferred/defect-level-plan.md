# Plan — `defect` level for `gh-issue-tracking-init` (DEFERRED)

| | |
| --- | --- |
| **Plan** | Add a `defect` level label + issue template to the gh-issue-tracking-init skill |
| **Target repo** | `intel-agency/agent-context` |
| **Status** | Deferred |
| **Extracted from** | [`../.completed/agent-context-fix-plan.md`](../.completed/agent-context-fix-plan.md) (was work item W3) |
| **Date extracted** | 2026-07-18 |
| **Reference** | Forensic finding F7 |

---

## Why this exists

The `gh-issue-tracking-init` skill ships a level taxonomy of `plan / epic / story / task` but has no `defect` level for bug-fix tasks. Forensic analysis of the skill applied to `intel-agency/gap-miner-v2-sierra46` flagged this as a gap (finding F7). It was originally W3 of the upstream fix plan but was **deferred** (commit `044b4bf defer defect level`) and extracted here so the rest of that plan could be archived as complete.

## Current state (verified 2026-07-18)

- `.agents/skills/gh-issue-tracking-init/assets/labels.json` ships `plan`, `epic`, `story`, `task` (priority/area/state labels too) — **no `defect`**.
- No `ISSUE_TEMPLATE/` directory exists anywhere in the skill (confirmed via `find`).
- `SKILL.md` "Out of scope" section (lines ~125–129) explicitly states defects are deferred and would require extending the Project `Level` single-select field.

## Work items

### D1 — Add the `defect` label

Append to `.agents/skills/gh-issue-tracking-init/assets/labels.json`:

```json
{ "name": "defect", "color": "b60205", "description": "Level: defect / bug-fix task" }
```

### D2 — Add the `defect` issue template

Create `.agents/skills/gh-issue-tracking-init/ISSUE_TEMPLATE/defect.md` (new directory). Model it on `task.md` if one exists; otherwise minimal front-matter:

```yaml
---
name: Defect
about: A bug or bug-fix task
labels: ['defect']
---
# Defect: [Short symptom]

## Reproduction
## Root cause
## Fix
## Verification
```

### D3 — Document `defect` as a supported level

In `.agents/skills/gh-issue-tracking-init/SKILL.md`:

- Add `defect` to the Level labels mention (`plan / epic / story / task / defect`).
- Update the `ensure-issue.ps1` orchestration step to pass `-Level defect` when the defect template is used.
- Reverse the "Out of scope / defects are deferred" text (lines ~125–129) — mark defects supported as of this change.

### D4 — Pester coverage

In `.agents/skills/gh-issue-tracking-init/scripts/tests/GhIssueTracking.Tests.ps1`, extend the `labels.json` taxonomy test (or add a new one) asserting:

- a `defect` entry is present in `assets/labels.json`;
- `ISSUE_TEMPLATE/defect.md` exists;
- the front-matter `name` (`Defect`) and `labels` (`['defect']`) match.

## Acceptance criteria

- [ ] `defect` label present in `assets/labels.json`.
- [ ] `ISSUE_TEMPLATE/defect.md` exists with correct front-matter.
- [ ] `SKILL.md` documents `defect` as a supported level and no longer defers it.
- [ ] Full Pester suite green with the new test(s).

## Notes

- **Path correction:** the original W3 referenced `scripts/labels.json`; the file has since moved to `assets/labels.json`. Use the current path.
- **Per-repo prerequisite:** the Project `Level` single-select field must gain a `defect` option in the Project UI (`gh` cannot add options to an existing single-select) — this remains a one-time manual step on each repo that uses the defect level, documented under the skill's "Known limitations".

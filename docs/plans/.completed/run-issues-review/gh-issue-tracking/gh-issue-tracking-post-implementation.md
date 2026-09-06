# Post-Implementation Report: GH Issue Tracking (Hierarchy-Creation Skill)

**Date:** 2026-07-14 (relocated 2026-07-14, see addendum)
**Status:** Implemented — skill + scripts + tests complete; two manual UI follow-ups remain.
**Related:** [`gh-issue-tracking-plan.md`](./gh-issue-tracking-plan.md) · [`gh-issue-tracking-plan-feedback.md`](./gh-issue-tracking-plan-feedback.md) · [scripts README](../../../.agents/skills/gh-issue-tracking-init/scripts/README.md) · [SKILL.md](../../../.agents/skills/gh-issue-tracking-init/SKILL.md)

> **Addendum (relocation):** The skill and its scripts were originally created at `.cursor/skills/gh-issue-tracking-init/SKILL.md` and `scripts/gh-issue-tracking/`. They were subsequently moved to **`.agents/skills/gh-issue-tracking-init/`** (skill + scripts colocated) so the skill is discoverable by all of this user's inference clients and fully **self-contained** — `common-auth.ps1`, `import-labels.ps1`, and `create-milestones.ps1` are now vendored copies inside the skill's own `scripts/` directory rather than being referenced from the repository-root `scripts/`. The sections below reflect the final, post-relocation state.

---

## Summary

Implemented **skill #1 (hierarchy-creation)** from the plan: an idempotent system that builds a `plan → epic → story → task` issue hierarchy on GitHub (Issues + Projects v2 + milestones + labels) for a target repo. The skill orchestrates a set of one-operation-per-script PowerShell scripts. Skill #2 (issue-implementation) remains deferred per the plan.

All scripts parse cleanly, the Pester suite (28 tests) passes, and there are no linter errors. Full end-to-end validation is a user-run smoke test against a throwaway repo (per the plan's Validation decision).

## Deliverables

### Skill
- [`.agents/skills/gh-issue-tracking-init/SKILL.md`](../../../.agents/skills/gh-issue-tracking-init/SKILL.md) — orchestration contract (parse plan → labels → milestones → project+fields → create issues top-down → link sub-issues → set board fields → dependencies), with conventions, idempotency, and dry-run-first workflow. Placed under `.agents/skills/` (rather than a vendor-specific `.cursor/skills/`) so it is discoverable by this user's other inference clients too.

### Operation scripts — [`.agents/skills/gh-issue-tracking-init/scripts/`](../../../.agents/skills/gh-issue-tracking-init/scripts/)
One script per operation; all idempotent; all support `-DryRun`. Colocated with the skill, making the whole skill **self-contained**.

| File | Role |
| ---- | ---- |
| `common.ps1` | Shared helpers: auth bootstrap (dot-sources the vendored `common-auth.ps1`), mockable `Invoke-Gh` wrapper, `owner/repo` parsing, numeric-DB-id + exact-title lookups |
| `labels.json` + `ensure-labels.ps1` | Canonical label taxonomy; delegates to the vendored `import-labels.ps1` |
| `ensure-project.ps1` | Create/link the Project and its custom fields (Level, Priority, Estimate, optional Phase) |
| `ensure-issue.ps1` | Idempotent create/update from a filled template body; prints the issue number |
| `link-sub-issue.ps1` | Parent↔child via the sub-issues REST API |
| `set-project-fields.ps1` | Add issue to board + set Level/Priority/Phase/Status/Estimate |
| `set-dependency.ps1` | Record blocked-by via the issue-dependencies REST API |
| `common-auth.ps1`, `import-labels.ps1`, `create-milestones.ps1` | **Vendored copies** of the general-purpose repo-root utilities (kept there too, since they're generic and used elsewhere) |
| `tests/GhIssueTracking.Tests.ps1` | Pester suite (29 tests, incl. a self-containment check) |
| `README.md` | Usage, limitations, and the user-run smoke-test flow |

### Templates (previously aligned)
The four templates in [`ISSUE_TEMPLATE/`](./ISSUE_TEMPLATE/) use the canonical labels and numbered title conventions (`Plan:`, `Epic <N>:`, `Story <N>.<M>:`, `Task <N>.<M>.<K>:`).

## Design decisions & conventions followed

- **Sub-issues are the sole hierarchy mechanism** (no issue-linked task lists); classic checklists are used only for in-issue items (acceptance criteria, sub-steps).
- **One script per operation**, composed by the skill; each is **idempotent** (match-and-skip/update, never duplicate) and supports **`-DryRun`**.
- Matched existing repo pwsh conventions: comment-based help, `[CmdletBinding()]`, `Repo` `ValidatePattern`, "planned actions" output, `common-auth.ps1` dot-sourcing.
- Issues matched by **exact numbered title** for idempotency; `ensure-issue.ps1` preserves the body on re-run unless `-UpdateBody` is passed.
- Workflow state lives in the Project **Status** field (not labels); milestones are assigned to the epic **and all descendants**.

## Reused / vendored repo assets

Originally referenced directly from `scripts/`; now **vendored** (copied) into the skill's own `scripts/` directory for self-containment. The originals remain at the repository root as general-purpose utilities, unaffected:

- `common-auth.ps1` — `Initialize-GitHubAuth`.
- `import-labels.ps1` — label create/update (driven by `labels.json`).
- `create-milestones.ps1` — milestone creation (conceptual work groups).

## Verified environment & API facts

- **`gh` 2.46.0** (older): lacks `gh issue create --parent`, so **sub-issues are created via the REST API** (`POST /repos/{owner}/{repo}/issues/{n}/sub_issues`, body `{ "sub_issue_id": <DB id> }`).
- **Issue dependencies** via REST (`POST /repos/{owner}/{repo}/issues/{n}/dependencies/blocked_by`, body `{ "issue_id": <DB id> }`). Both APIs key off the issue's **numeric database id**, not its number.
- **`gh project field-create`** supports single-select fields; **no `view-create`** exists.
- Tooling present: **PowerShell 7.6.3**, **Pester 5.7.1**.

## Known limitations (surfaced, not worked around)

1. **Project views are not automatable** via `gh`/API. `ensure-project.ps1` prints the four views to create once in the UI (By Phase, By Status, By Epic, Current work).
2. **Built-in Status field options** — `gh` 2.46 cannot add options to an existing single-select field, so `In Review` and `Blocked` may need a one-time manual add.

## Manual follow-up checklist

- [ ] Add the four Project **views** in the UI (By Phase, By Status board, By Epic, Current work).
- [ ] Add missing **Status** options (`In Review`, `Blocked`) if desired.
- [ ] (Optional) Upgrade `gh` to a version with native `--parent` / single-select option editing to reduce manual steps.

## Testing status

- **Static:** all 10 scripts (7 operation scripts + 3 vendored helpers) parse via the PowerShell AST parser.
- **Unit + contract (Pester, 29 tests, passing):** `common.ps1` helper logic (with `gh` mocked), label-taxonomy assertions (canonical labels present; workflow-state labels absent), per-script contracts (parse cleanly, expose `-DryRun`, reject malformed `-Repo`), and a self-containment check (vendored helpers present locally). No repo mutation.

  ```bash
  pwsh -NoProfile -Command "Invoke-Pester -Path .agents/skills/gh-issue-tracking-init/scripts/tests -Output Detailed"
  ```

- **End-to-end smoke test:** user-run against a throwaway repo (`-DryRun` first), documented in the [scripts README](../../../.agents/skills/gh-issue-tracking-init/scripts/README.md). Not yet executed.

## Out of scope / deferred

- **Defects/bugs** — no `defect` template or label yet.
- **Issue-implementation skill (#2)** — current-issue selection algorithm and intra-level ordering.

## File inventory

```
.agents/skills/gh-issue-tracking-init/
├─ SKILL.md
└─ scripts/
   ├─ common.ps1
   ├─ common-auth.ps1        (vendored)
   ├─ import-labels.ps1      (vendored)
   ├─ create-milestones.ps1  (vendored)
   ├─ labels.json
   ├─ ensure-labels.ps1
   ├─ ensure-project.ps1
   ├─ ensure-issue.ps1
   ├─ link-sub-issue.ps1
   ├─ set-project-fields.ps1
   ├─ set-dependency.ps1
   ├─ README.md
   └─ tests/GhIssueTracking.Tests.ps1
```

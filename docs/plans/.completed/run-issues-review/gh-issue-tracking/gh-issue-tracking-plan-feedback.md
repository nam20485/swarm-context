# Feedback: GH Issue Tracking Plan

**Date:** 2026-07-14
**Author:** AI Assistant
**Document under review:** [`gh-issue-tracking-plan.md`](./gh-issue-tracking-plan.md)

> **How to use this doc:** Each item below has a **My feedback** block for your response (decision, notes, or "accept/reject"). The open questions and editorial sections have fill-in areas too.

---

## Overall Assessment

The plan is directionally strong and well structured. The four-level hierarchy is well defined, it correctly leans on native GitHub features (sub-issues and blocking/blocked-by dependencies), and it enumerates concrete outputs (two skills, four templates, and helper scripts).

The main thing holding it back from being *executable* is that it describes the **end state** (a hierarchy of linked issues) more clearly than the **mechanics and decisions** a skill/script would need to build that state deterministically. The recommendations below are grouped by priority so the highest-impact ambiguities can be resolved first.

### Strengths

- Issue templates exist for every level (`application-plan.md`, `epic.md`, `story.md`, `task.md`).
- Dependency handling is explicit via GitHub blocking/blocked-by (lines 44–46).
- Documentation links are included for task lists, sub-issues, and issue dependencies.
- Outputs are separated into Skills / Templates / Scripts.

> **My feedback:** *Add your response here.*

---

## High Priority (resolve before implementation)

### 1. Reconcile whether tasks are sub-issues or checklist items

The plan contradicts itself on the atomic level:

- Line 34 describes tasks as checkbox list items inside their parent story ("stories' list are the tasks").
- Line 72 says to use "the task template for each task **sub-issue**", i.e. tasks are full issues.

These are two different data models. Pick one and make it consistent everywhere (Strategy, Hierarchy, Creating-the-hierarchy, Templates). Recommendation: make tasks **full sub-issues** (so they get their own template, labels, assignee, dependencies, and board presence); the parent story's progress bar then comes from the sub-issues section automatically — no issue-linked task list needed (see #13). If tasks were only checklist items, `task.md` should not be an issue template.

> **My feedback:** Resolved by #13 — tasks are full sub-issues, not issue-linked checklist items. Phases are very large groups of epics, that encapsulate almost an entire plan. Or at least one development effort worth of plan. They are mainly used to push work out of the current development plan and into future efforts and also avoid having to break down into detail in the current plan.

### 2. Define how "phases" are represented in GitHub

Phases are introduced as an optional grouping of epics (lines 9, 11, 30) but the mechanism is never specified. Options: a **milestone**, a **Projects v2 single-select field**, an **iteration field**, or a **label**. Because the creation skill/scripts must produce this deterministically, name the concrete mechanism (recommendation: a Project single-select "Phase" field, or milestones if phases map 1:1 to releases).

> **My feedback:**  Project single-select "Phase" field. These are optional so may not occur at all in a given repo.
>
> **Resolved:** Orthogonal to milestones — an epic can carry both a Phase (optional; current-vs-deferred effort) and a Milestone (conceptual group).

### 3. Define a label taxonomy — and align the templates to it

The plan says to "use labels" but never defines them, and the templates already disagree with each other:

- `application-plan.md` / `epic.md`: `plan, design, architecture`
- `story.md`: `story, enhancement`
- `task.md`: `task`

Define one canonical set and make every template use it. Suggested taxonomy:

- **Level:** `plan`, `epic`, `story`, `task`, `defect`
- **Priority:** `P0`, `P1`, `P2`, `P3`
- **Area:** e.g. `area/ai`, `area/ui`, `area/core`, `area/infra`, `area/docs`
- **Status (cross-cutting):** `blocked`, `needs-review`, `wontfix` (workflow state like *in progress* / *done* lives in the Project **Status** field, not labels — see #5)

> **My feedback:** use the recommended "Suggested taxonomy" set above
>
> **Resolved:** Adopt the taxonomy. Workflow status is the Project **Status** field (source of truth), so `in-progress`/`done` are not labels.

### 4. Define the milestone strategy

State what a milestone represents: a phase, a release, or an epic. This drives how the skill assigns the milestone field (line 42) and how progress rolls up. Recommendation: milestone = release (or phase, if phases align 1:1 with releases); do **not** overload milestones for both.

> **My feedback:** Milesones are groups of epics in the plan, i.e. "POC", "MVP" or UI, or "Server". Conceptual groups of work.
>
> **Resolved:** Native GitHub **milestones** = conceptual work groups (POC/MVP/UI/Server). Assign the milestone to the **epic and all its descendant stories/tasks** so the milestone % reflects granular progress. Orthogonal to Phase (#2).

### 5. Specify the Project (Projects v2) configuration

"Board views e.g. phases" (line 11) is too vague for a deterministic script. Specify:

- **Custom fields:** Status, Level, Phase (or Iteration), Priority, Estimate.
- **Views:** by Phase, by Status (board), by Epic, and a "current work" filtered view.
This is a prerequisite for the "implement an issue" skill to locate the current issue (see #9).

> **My feedback:** Create the Project **and** its board views now. Custom fields: **Status, Level, Phase, Priority, Estimate** (Milestone is native). Views: by Phase, by Status (board), by Epic, and a filtered *current work* view.

### 6. Address "defects" — they're in scope but missing from the model

The Description (line 5) includes "defects", but there is no defect placement in the hierarchy and no defect template. Either add a `defect.md` template and define where defects attach (standalone? child of a story/epic?), or explicitly scope defects out for now.

> **My feedback:** We will address defects later. They are not in scope for this first version of the plan.

---

## Medium Priority (technical prerequisites & correctness)

### 7. Document the GitHub API/auth prerequisites for the scripts

Sub-issues and Projects v2 are **GraphQL-first**; the REST API coverage is limited. The scripts will need:

- `gh` CLI authenticated with the right scopes (Projects requires the `project` scope; classic tokens need `read:project`/`project`).
- GraphQL mutations for creating sub-issue relationships and setting Project field values.
Call this out so the scripts aren't written against REST endpoints that don't exist.

> **My feedback:** OK. This is dealt with, ~scripts/ dir has scripts for validating gh cli auth and scopes, and $GIHUB_TOKEN is pre-defined in the environment.

### 8. Note sub-issue limits and nesting depth

GitHub imposes limits (roughly ~100 sub-issues per parent and a bounded nesting depth). The four-level plan→epic→story→task chain is within limits, but large plans could hit the per-parent cap. Document the limits and a fallback (e.g., split oversized epics).

> **My feedback:** Ok sounds good. Shouldnt be a problem. So dont spend too much effort on it.

### 9. Define the "implement an issue" selection algorithm

The skill "finds the current issue from the plan issues and project board views" (line 61) but the selection logic is unspecified. Define it concretely, e.g.: *the highest-priority, unblocked, open `task` in the active phase/milestone; ties broken by board order.* Also define behavior when `$ghissue` is omitted **and** multiple candidates are in progress.

> **My feedback:** Sounds good- we will spend more time on this later. Lets focus on the hierarchy creation skill first.

### 10. Specify script language, location, and the one-op-per-script contract

Line 76 says to create a script per operation, but not where they live or in what language. The repo currently uses PowerShell + batch under `scripts/`, while the dev environment here is Linux — recommend **cross-platform** scripts (PowerShell 7 `pwsh`, or bash) driving `gh`. Define:

- a directory (colocated with the skill: `.agents/skills/gh-issue-tracking-init/scripts/`, self-contained),
- the discrete operations (create-label-set, create-milestone, create-project, create-issue, link-sub-issue, set-project-fields, set-dependency),
- the input/output contract for each (arguments, stdout, exit codes) so skills can compose them.

> **My feedback:** Powershell scripts in the `scripts/` dir.
>
> **Resolved:** Grouped in `.agents/skills/gh-issue-tracking-init/scripts/` (PowerShell 7 / `pwsh`, cross-platform), colocated with the skill so it's self-contained (later moved from an initial `scripts/gh-issue-tracking/` location).

### 11. Make issue templates discoverable (or clarify they're programmatic)

The templates live in `docs/plans/gh-issue-tracking/ISSUE_TEMPLATE/`, so GitHub's UI will **not** surface them (it only reads `.github/ISSUE_TEMPLATE/`). Clarify whether they are consumed programmatically by the scripts (fine as-is) or should be mirrored/moved to `.github/ISSUE_TEMPLATE/` for manual issue creation. If both manual and scripted creation are desired, keep one source of truth and copy at build time.

> **My feedback:** Only used by the skills to create the hierarchy structure. So no need to mirror to `.github/ISSUE_TEMPLATE/` for manual use. Make sure they are hidden from the GitHub UI.

### 12. Define idempotency / re-run behavior

The scripts are described as deterministic (line 76) but not idempotent. Specify what happens on re-run: does the skill detect existing labels/milestones/project/issues and skip or update them, or create duplicates? This is critical for a creation skill that may be run more than once against the same repo.

> **My feedback:** Make the skill idempotent so it can be run multiple times against the same repo, subsequent runs update existing hierachrcy in the GH repo.

### 13. Use sub-issues as the single source of truth — drop issue-linked task lists

**Decision applied:** use sub-issues only for the parent↔child hierarchy; do **not** link task-list items to child issues. Rationale:

- GitHub's rich *tasklist blocks* (the `[tasklist]` code-fence feature that provided issue hierarchy and the `Tracked` / `Tracked by` fields in Projects) were **retired on April 30, 2025** and replaced by sub-issues ([GitHub Changelog](https://github.blog/changelog/2025-02-18-github-issues-projects-february-18th-update/)). Only plain markdown checkboxes remain, and they are a separate, **unsynced** layer.
- Sub-issues already provide the parent/child relationship, automatic progress rollup (closing a child updates the parent), a REST/GraphQL API for automation, and native Projects v2 integration (`has:parent-issue`, `has:sub-issues-progress`, grouping by parent). Issue-linked task lists add none of this and would only duplicate it.
- Maintaining both would mean two representations that drift, two progress indicators that can conflict, and extra script operations to keep them in sync (see #12).

**Keep** plain ("classic") task lists for **non-issue** checklist items *within* an issue — e.g., acceptance criteria, definition-of-done, and sub-steps that don't warrant their own issue. These aren't linked to child issues and are unaffected by this change; the templates already use them this way.

Plan changes this implies:

- Rewrite the "two methods" section (plan lines 13–17) so **sub-issues are the sole hierarchy mechanism**; remove the task-list → child-issue linking method (method 1) and its `about-tasklists` doc link.
- Update "Creating the hierarchy" (plan lines 34–36): drop the **IMPORTANT** note that mandates linking task-list items to child issues; keep sub-issue creation.
- Remove the `link-tasklist-item` script operation (see #10).

> **My feedback:** DECIDED — sub-issues only for hierarchy/linking; stop linking task-list items to child-issue types. Classic (unlinked) task lists are still used for checklist items inside issues (acceptance criteria, sub-steps, etc.).

---

## Lower Priority (completeness & polish)

### 14. Add acceptance criteria for the system itself

The templates emphasize acceptance criteria, yet the plan has none for its own deliverables. Add a short "Definition of Done" for the system, e.g. *both skills exist and pass a dry-run against a test repo; all four templates validated; label/milestone/project created; a sample plan hierarchy builds end-to-end.*

> **My feedback:** add reasonable acceptance criteria for the skills and scripts.

### 15. Add a validation/test strategy for the skills and scripts

Describe how the deliverables are verified: a `--dry-run` mode, a scratch/test repository, and a smoke test that builds a small plan→epic→story→task tree and asserts the links, fields, and dependencies.

> **My feedback:** add `--dry-run` mode user is responsible for running inside a test repo, with smoke test and end result validation. Add pester test suite for powersdhell scripts also.

### 16. Define "done" and state synchronization

With sub-issues as the source of truth (see #13), define completion as **closing the sub-issue** — the parent's progress then rolls up automatically. Clarify how that relates to the board Status column (e.g., closing an issue moves it to Done, or the Done column drives closing). Classic in-issue checklists (acceptance criteria) are informational only and don't affect rollup.

> **My feedback:** add it

### 17. Standardize issue title conventions

Templates use different title styles (`Story:`, `[ProjectName] – [PhaseName] - Epic`, `[ProjectName] – Complete Implementation`). Define one convention across levels, e.g. `[Level] <Name>` or `Level: <Name>`, and align every template.

> **My feedback:** "Epic 1: <Name>", "Story 1.1: <Name>", "Task 1.1.1: <Name>"
>
> **Resolved:** Top-level plan issue title = `Plan: <Name>`. All templates updated to this scheme; the skill assigns/maintains the numbering idempotently.

### 18. Define ordering/priority within a level

State how order is captured within a level (task-list order, board manual rank, or a Priority field), since the "implement an issue" skill depends on it.

> **My feedback:** 2nd, implementation skill deferred (to later phase)

---

## Editorial / Typos

| Line | Current | Suggested |
| ---- | ------- | --------- |
| 9 | "phases, epcis, stories" | "phases, epics, stories" |
| 30 | "when the the effort" | "when the effort" |
| 34 | "epics' listg are the stories" | "epics' lists are the stories" |
| 34 | "stories' list are the tasks)" (no period) | "stories' lists are the tasks)." |
| 34 | "and  another level" (double space) | "and another level" |
| 38 | "children of an GH issue" | "children of a GH issue" |
| 38 | "adding  a link" (double space) | "adding a link" |
| 58 & 60–61 | The paragraph and the bullet list state the same two skills twice | Keep one (recommend the bullets) to remove redundancy |
| 70 | `**Task** (...)` missing the leading `-` bullet used by the other three entries | `- **Task** (...)` |
| 76 | "repo slug. This way" (missing closing `)` after slug) | "repo slug). This way" |
| 76 | "each time the skill runs it run deterministically" | "each time the skill runs, it runs deterministically" |
| 76 | "should be creatd" | "should be created" |
| 76 | "each of the oepratirons the scripts need to perfrom" | "each of the operations the scripts need to perform" |

> **My feedback:** Fix all

---

## Suggested Additional Sections for the Plan

1. **Prerequisites** — `gh` CLI, auth scopes (incl. Projects), GraphQL usage note.
2. **Label & Milestone Taxonomy** — the canonical sets from #3 and #4.
3. **Project Board Specification** — fields and views from #5.
4. **Idempotency & Re-run Semantics** — from #12.
5. **Definition of Done / Acceptance Criteria** — from #14.
6. **Validation & Testing** — from #15.
7. **Defects/Bugs** — from #6 (or an explicit out-of-scope note).

> **My feedback:** Addressed above (arent these addressed by the above items?), add

---

## Open Questions

Fill in the **My answer** column with your decision for each.

| # | Question | My answer |
| - | -------- | --------- |
| 1 | Are tasks first-class issues, checklist items, or both? (#1) | First-class **sub-issues** (per #13 decision); not issue-linked checklist items. |
| 2 | What is a phase in GitHub terms — milestone, project field, or iteration? (#2) | Project single-select **Phase** field (optional); orthogonal to milestones. |
| 3 | Does a milestone map to a phase or a release? (#4) | Neither — native GH **milestone** = conceptual work group (POC/MVP/UI/Server), assigned to the epic + all descendants. |
| 4 | Are defects in scope for the first version? (#6) | No — deferred to a later version. |
| 5 | Should templates also be mirrored to `.github/ISSUE_TEMPLATE/` for manual use? (#11) | No — programmatic-only; kept out of GH's template locations so the UI won't surface them. |
| 6 | What language/runtime should the scripts target (pwsh vs bash)? (#10) | PowerShell (`pwsh`) in `.agents/skills/gh-issue-tracking-init/scripts/` (self-contained). |

My feedback: Addressed above

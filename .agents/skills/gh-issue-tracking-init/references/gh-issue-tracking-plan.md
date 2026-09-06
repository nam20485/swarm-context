# Plan for a GitHub Issue-Based Planning & Development Tracking System

## Description

Use GitHub Issues and Projects to specify and track plans and development for new apps and features. A repo's plan is expressed as a hierarchy of linked issues (plan → epic → story → task), organized and visualized with a GitHub Project, milestones, and labels, so that current progress, what's complete, and what remains are all visible at a glance.

> Defects/bugs are **out of scope for this first version** (see [Out of Scope](#out-of-scope-v1)).

## Strategy

Organize plans and development into a four-level hierarchy of **plan → epic → story → task**, where every level is a full GitHub issue and parent↔child relationships are captured with GitHub's native **sub-issues** feature.

- Use a **GitHub Project (v2)**, **milestones**, **labels**, and Project **board views** to organize the issues and view state and completion.
- Capture inter-issue dependencies with GitHub's **blocking / blocked-by** relationships.
- Optionally group epics into **phases** (an optional Project field) and into **milestones** (conceptual groups of work).

## Plan/Issue Hierarchy Structure

There are four levels of the hierarchy:

1. Main application **plan** issue
2. **Epics**
3. **Stories**
4. **Tasks**

The top level is the overall application plan, which is broken down into epics, epics are broken down into stories, and stories are broken down into tasks. **Tasks are the atomic units of work.** Every level — including tasks — is a full GitHub issue with its own template, labels, assignees, and dependencies.

## Grouping: Phases, Milestones, and the Project

Epics can be grouped along two **orthogonal** axes. An epic may belong to both a phase and a milestone at the same time.

### Phases (optional)

- Represented as a **Project single-select "Phase" field**.
- A phase is a very large grouping of epics — roughly one development effort's worth of the plan. Phases are used mainly to **push work out of the current development effort into a future one**, and to avoid breaking future work down into detail prematurely.
- Phases are **optional** and may not appear at all in a given repo.

### Milestones

- Represented as **native GitHub milestones**.
- A milestone is a **conceptual group of work** (e.g., `POC`, `MVP`, `UI`, `Server`).
- The milestone is assigned to the **epic and all of its descendant stories and tasks**, so the milestone's completion percentage reflects granular progress.

## Linking Model — Sub-Issues Only

**Sub-issues are the single source of truth for the parent↔child hierarchy** at every level (plan → epic → story → task), using GitHub's [sub-issues feature](https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/adding-sub-issues).

- **Do not** use issue-linked task lists to represent the hierarchy. GitHub's rich *tasklist blocks* (which previously provided issue hierarchy and the `Tracked`/`Tracked by` fields) were [retired on April 30, 2025](https://github.blog/changelog/2025-02-18-github-issues-projects-february-18th-update/) and replaced by sub-issues. Sub-issues already provide the parent/child relationship, automatic progress rollup, a REST/GraphQL API, and native Project integration — so a parallel task-list layer would only duplicate them and drift out of sync.
- **Classic (plain) task lists** are still used, but **only for non-issue checklist items within an issue** — e.g., acceptance criteria, definition-of-done, and sub-steps that don't warrant their own issue. These are not linked to child issues.

**IMPORTANT**: Always use the GitHub **sub-issue** functionality to create children of an issue; never represent hierarchy by manually pasting child-issue links or by linking task-list items to child issues.

### Dependencies

Capture dependencies between issues with GitHub's [blocking / blocked-by](https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/creating-issue-dependencies#marking-an-issue-as-blocked-by-or-blocking-another-issue) functionality.

**IMPORTANT**: Always use the GitHub blocking / blocked-by functionality to capture dependencies between issues.

## Creating the Plan/Issue Hierarchy Structure

Create the hierarchy top-down, using sub-issues at every level:

1. Create the overall **plan** issue (from the application-plan template).
2. Create each **epic** as a **sub-issue** of the plan.
3. Create each **story** as a **sub-issue** of its epic.
4. Create each **task** as a **sub-issue** of its story.
5. Create/ensure the **Project**, its **fields**, and its **views**; create/ensure the **milestones** and the **label** set.
6. Connect each issue's **Project** item and set its fields (Level, Phase, Priority, Estimate, Status); assign its **milestone** (epics and all descendants).
7. Set **blocking / blocked-by** dependencies between issues.

**IMPORTANT**: Always connect issues to the relevant Project and milestone and set their Project fields.

This process is **idempotent** — see [Idempotency & Re-run Semantics](#idempotency--re-run-semantics).

## Issue Title & Numbering Conventions

Use hierarchical, numbered titles so the level and position are obvious from the title alone:

| Level | Title format | Example |
| ----- | ------------ | ------- |
| Plan | `Plan: <Name>` | `Plan: Support Assistant` |
| Epic | `Epic <N>: <Name>` | `Epic 1: Inference Engine` |
| Story | `Story <N>.<M>: <Name>` | `Story 1.2: Streaming API` |
| Task | `Task <N>.<M>.<K>: <Name>` | `Task 1.2.3: Add cancellation token` |

The hierarchy-creation skill assigns and maintains this numbering **idempotently** (re-runs keep numbers stable and renumber only when the structure changes).

## Label & Milestone Taxonomy

A single canonical label set is used across all templates and issues:

- **Level:** `plan`, `epic`, `story`, `task` (`defect` is reserved for a later version)
- **Priority:** `P0`, `P1`, `P2`, `P3`
- **Area (examples, extensible):** `area/ai`, `area/ui`, `area/core`, `area/infra`, `area/docs`
- **Status (cross-cutting):** `blocked`, `needs-review`, `wontfix`

> Workflow state (Todo / In Progress / In Review / Done) is tracked by the Project **Status** field, **not** by labels.

**Milestones** are conceptual groups of work (e.g., `POC`, `MVP`, `UI`, `Server`) and are assigned to each epic and all of its descendants.

## Project Board Specification

The hierarchy-creation skill creates the Project together with the following configuration.

### Custom fields

| Field | Type | Purpose |
| ----- | ---- | ------- |
| Status | Single-select (`Todo`, `In Progress`, `In Review`, `Blocked`, `Done`) | Workflow state (source of truth) |
| Level | Single-select (`plan`, `epic`, `story`, `task`) | Hierarchy level |
| Phase | Single-select (optional) | Current-vs-deferred effort grouping |
| Priority | Single-select (`P0`–`P3`) | Prioritization |
| Estimate | Number | Rough sizing |

(*Milestone* is a native Project field and does not need to be created.)

### Views

- **By Phase** — grouped by the Phase field.
- **By Status** — board view grouped by Status.
- **By Epic** — grouped by parent epic.
- **Current work** — filtered view of open, unblocked items in the active phase/milestone.

## Prerequisites

- **`gh` CLI** authenticated against the target repo. `$GITHUB_TOKEN` is pre-defined in the environment, and `scripts/` already contains scripts that validate `gh` CLI auth and scopes.
- Sub-issues and Projects v2 are **GraphQL-first**; the scripts use the GraphQL API where the REST API is insufficient (creating sub-issue relationships, setting Project field values).
- **Sub-issue limits:** up to ~100 sub-issues per parent and up to 8 levels of nesting. The four-level plan→epic→story→task hierarchy is well within these limits; if an epic would exceed the per-parent cap, split it.

## Idempotency & Re-run Semantics

The hierarchy-creation skill is **idempotent** and may be run multiple times against the same repo:

- On first run it creates the labels, milestones, Project (fields + views), and the full issue hierarchy.
- On subsequent runs it **detects existing** labels/milestones/Project/issues (matched by level + numbered title) and **updates them in place** rather than creating duplicates.
- Numbering (see title conventions) stays stable across runs.

## Definition of Done & State Synchronization

- With sub-issues as the source of truth, **completion = closing the sub-issue**; the parent's progress rolls up automatically.
- In-flight workflow state is tracked by the Project **Status** field; closing an issue moves it to `Done`.
- Classic in-issue checklists (acceptance criteria, etc.) are **informational only** and do not drive rollup.

## Implementation of the System

### Outputs

The outputs of this plan are two skills, four issue templates, and a set of scripts.

#### Skills

1. **Hierarchy-creation skill** *(current focus)* — initializes the plan/issue/Project/milestone/label hierarchy in a given GH repo (given a GH repo URL or slug, `$ghrepo`). Idempotent.
2. **Issue-implementation skill** *(deferred to a later phase)* — implements an issue in a repo where this system is set up (given an issue number or title, `$ghissue`; if not provided, the current issue is selected from the plan issues and board views). The selection algorithm and intra-level ordering are deferred with this skill.

#### Templates

Issue templates for each level of the hierarchy live in the skill's [`../assets/templates/`](../assets/templates) directory:

- **Application Plan** ([`../assets/templates/application-plan.md`](../assets/templates/application-plan.md)) — top-level plan issue: overview, goals, technology stack, features, system architecture, phased implementation plan (with epic-grouped subsections in Phase 2), mandatory requirements (testing, docs, build, infrastructure with SHA-pinned Actions), acceptance criteria, risks, timeline, and success metrics.
- **Epic** ([`../assets/templates/epic.md`](../assets/templates/epic.md)) — epic-level issue scoped to a single project/component: overview, project, component, goals, component-specific technology stack, epic stories, component architecture, project structure area, story-based implementation plan, mandatory requirements, acceptance criteria, risks, timeline, and success metrics.
- **Story** ([`../assets/templates/story.md`](../assets/templates/story.md)) — story-level issue: objective, in/out of scope, task plan, acceptance criteria, validation commands, dependencies (related issues, env vars, external services, data requirements), risks & mitigations, test strategy (unit/integration/e2e), rollback steps, implementation notes, and related documentation.
- **Task** ([`../assets/templates/task.md`](../assets/templates/task.md)) — task-level issue: description, acceptance criteria, validation commands, dependencies, risks & mitigations, test strategy, and rollback steps.

These templates are **consumed programmatically by the skill only** (passed to `ensure-issue.ps1 -BodyFile`). They ship inside the skill's `assets/templates/` directory — **not** in `.github/ISSUE_TEMPLATE/` or any repo-root `ISSUE_TEMPLATE/` — so GitHub's UI does **not** surface them in the "New issue" template chooser; they are fill-in bodies for the hierarchy the skill builds, not interactive issue forms.

When creating the hierarchy, use the application-plan template for the plan issue, the epic template for each epic sub-issue, the story template for each story sub-issue, and the task template for each task sub-issue.

#### Scripts

Scripts are **PowerShell 7 (`pwsh`, cross-platform)** and live in `.agents/skills/gh-issue-tracking-init/scripts/` — colocated with the skill so it is self-contained (a few general-purpose GitHub CLI helpers are vendored there too; see the skill's README). There is **one script per discrete operation** (not one script for the whole skill), so the skill runs deterministically by composing them. Each script has a defined contract (arguments, stdout, exit codes) and supports a **`--dry-run`** mode.

Representative operations:

- `create-label-set` — create/ensure the canonical labels.
- `create-milestone` — create/ensure a milestone.
- `create-project` — create/ensure the Project, its fields, and its views.
- `create-issue` — create/ensure an issue from a template at a given level.
- `link-sub-issue` — create the parent↔child sub-issue relationship.
- `set-project-fields` — set an item's Project fields (Level, Phase, Priority, Estimate, Status).
- `set-dependency` — set a blocking / blocked-by relationship.

## Acceptance Criteria

For the deliverables of this plan (the skills and scripts):

- [ ] The hierarchy-creation skill creates labels, milestones, the Project (fields + views), and the full plan→epic→story→task issue hierarchy from templates.
- [ ] Parent↔child relationships are created as **sub-issues**; no issue-linked task lists are used for hierarchy.
- [ ] Milestones are assigned to each epic and all its descendants; Project fields (Level, Phase, Priority, Estimate, Status) are set.
- [ ] Dependencies are set via blocking / blocked-by.
- [ ] Issue titles follow the numbered convention and numbering is stable across re-runs.
- [ ] The skill is **idempotent** — a second run updates existing items without creating duplicates.
- [ ] All operation scripts run under `pwsh`, support `--dry-run`, and have a Pester test suite.

## Validation & Testing

- **`--dry-run` mode** on every script and on the skill, printing the intended operations without mutating the repo.
- The **user is responsible for running against a dedicated test repo** (not production).
- A **smoke test** builds a small plan → epic → story → task tree and validates the sub-issue links, Project fields, milestone assignment, and dependencies.
- A **Pester test suite** covers the PowerShell scripts.

## Out of Scope (v1)

- **Defects/bugs** — no defect template or `defect` label is created yet; defect handling is deferred to a later version.
- **Issue-implementation skill** — the current-issue selection algorithm and intra-level ordering are deferred to a later phase; this plan focuses on the hierarchy-creation skill first.

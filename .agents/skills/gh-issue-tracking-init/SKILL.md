---
name: gh-issue-tracking-init
description: Use when initializing (or re-syncing) a GitHub issue-based planning hierarchy in a repo — a plan → epic → story → task tree of linked sub-issues plus a Projects v2 board, milestones, and labels. Composes the idempotent PowerShell operation scripts in this skill's own scripts/ directory (self-contained) to build the structure from a plan document, a feature list, or the issue templates. Trigger when the user asks to "set up GH issue tracking", "create the plan/issue hierarchy", "scaffold epics/stories/tasks as issues", or names a target repo ($ghrepo) to initialize or extend.
---

# gh-issue-tracking-init

Initialize the GitHub issue-tracking hierarchy — defined in the design plan
at [`references/gh-issue-tracking-plan.md`](./references/gh-issue-tracking-plan.md)
— for a target repository. The heavy lifting is done by idempotent PowerShell
operation scripts in this skill's own
[`scripts/`](./scripts/) directory (see its
[`README.md`](./scripts/README.md)); this skill decides
**what** to create from the plan and composes those scripts to do it.

This skill is **fully self-contained**: its `scripts/` directory vendors the
small set of general-purpose GitHub CLI helpers it depends on
(`common-auth.ps1`, `import-labels.ps1`, `create-milestones.ps1` — also kept at
the repository root as generic utilities), its issue body templates live in
[`assets/templates/`](./assets/templates/), and the canonical label taxonomy
ships as [`assets/labels.json`](./assets/labels.json). The skill has no
dependency on anything outside its own directory — copy
`gh-issue-tracking-init/` into another repo and it works unmodified.

## Inputs

All inputs have defaults and may be omitted — the skill then runs against the repo
it is invoked from.

- `$ghrepo` — target repository as `owner/repo` (or a URL you normalize to that).
  **Default when omitted:** the repository the skill is running from — the GitHub
  repo of the current working directory, resolved with
  `gh repo view --json nameWithOwner -q .nameWithOwner` (equivalently, the `origin`
  remote of the enclosing git repo). Use this default unless the user names a
  different repo.
- **Plan source** — a description of the epics/stories/tasks that you map onto the
  four levels and the numbering scheme. Two source classes:
  - **Plan doc** (a filled plan document). **Default when omitted:** resolve
    `plan_docs/**/*.md` non-interactively using filename role classification
    (match any slug, word-boundary, case-insensitive):

    - **Primary plan** → issue tree. Slugs: `development-plan`, `development plan`,
      `app-plan`, `application-plan`, `implementation`, `implementation-spec`,
      `implementation plan`, `specification`. Parse into plan→epic→story→task nodes.
    - **Architecture** → context. Slugs: `architecture`, `architecture-guide`,
      `architecture-plan`, `architecture overview`. Reference in the Plan body and
      relevant epic bodies.
    - **Reference / background** → context. Everything else (`strategic`,
      `feasibility`, `vision`, `context`, `research`, …). Reference in the Plan body
      only.

    > Bare `plan` is NOT a primary slug — words like "execution plan" or "strategic plan" contain "plan" but are not development plans.

    Resolution rules (deterministic; log the choice; never block except rule 5):
    1. Exactly one primary plan → use it. Fold architecture + reference docs into the Plan body as supporting context.
    2. No primary plan, one doc total → use that doc as the primary plan.
    3. No primary plan, multiple docs → pick the doc with strongest task structure (count headings matching `^#+\s*(T-?\d+[-.]?\d*|Task\s|Phase\s|Story\s|Epic\s)`); tie-break by filename order.
    4. Multiple primary plans → use the first in filename order; log rationale (never prompt).
    5. Zero docs (`plan_docs/` missing or empty) → hard stop: require the user to supply a plan source explicitly.

    The only case that prompts is an empty/missing `plan_docs/` with no plan supplied.
  - **Feature list** (or the user describing features rather than a plan) → the
    **[Feature-list plan source (feature campaigns)](#feature-list-plan-source-feature-campaigns)**
    flow applies instead of the plan-doc resolver: derive a campaign Plan root from
    the features per that section. A supplied feature list also satisfies rule 5
    above (nothing to prompt for).
- `$ExistingPlanMode` — applies **only when the plan source is a feature list**:
  `continue-existing` (attach the campaign to the newest open plan root; default) or
  `new-feature-plan` (always create a new wrapper Plan issue). The default is the
  constant **`DEFAULT_EXISTING_PLAN_MODE = 'continue-existing'`**, whose canonical
  machine value is the `-Mode` parameter default in
  [`scripts/resolve-plan-root.ps1`](./scripts/resolve-plan-root.ps1) — this document
  references it by name and must not drift. Plan-doc sources ignore the mode
  entirely (they match their plan issue by title).

  ## Mapping the plan onto the hierarchy

Plan docs rarely use the words "epic"/"story"/"task" verbatim — they organize work
under their own top-level groupings. Mapping those groupings onto the four levels is
the single most load-bearing decision in the run; apply it deliberately:

- **Whole plan → Plan** (one issue).
- **The plan's top-level work groups → Epics.** These are frequently titled
  **"Phases"** (Phase 0, Phase 1, …), but the same role is played by "Sprints",
  "Stages", "Groups", "Pillars", or numbered milestone sections. **A plan whose top
  layer is "Phases" MUST be treated as: each Phase = one Epic** — this is mandatory,
  not a guess.
- **The plan's leaf work items → Stories.** These are the atomic, independently-
  completable units the plan numbers as tasks (e.g. `T-x.y`, "Task 3.1"). Each
  becomes one Story.
- **Introduce Tasks (the 4th level) only when the plan itself nests a sub-tier
  beneath those leaf items.** A plan structured as Group → Item has no task level;
  its Stories are leaves — that is correct, not a gap.

> **Terminology collision — read carefully.** A plan's **"Phase"** (a top-level work
> group → becomes an Epic) is **NOT** this skill's optional **`Phase` Project field**
> (a cross-cutting single-select board field; see *Conventions*). Same word, different
> meaning. Do **not** create the Phase field just because the plan says "phase" — the
> plan's phases have already become Epics, and adding the field would duplicate that.
>
> **Plan-task id traceability.** When the plan keys its dependency / parallel-execution
> graph by an id (e.g. a *Parallel Execution Map* referencing `T-x.y`), surface that id
> on the corresponding issue so the plan↔issue mapping is self-documenting — e.g. a
> parenthetical suffix in the title (`Story 2.3: Repository Layer (T-1.3)`).

## Feature-list plan source (feature campaigns)

When the plan source is a **feature list** (or the user describes features rather
than a plan), do NOT wrap the list in a hollow Plan issue and do NOT stop for a plan
doc — derive a **feature campaign**. The campaign narrative lives in the **plan
body**: either a new wrapper Plan issue (`Plan: <CampaignName>`, template
[`assets/templates/feature-campaign-plan.md`](./assets/templates/feature-campaign-plan.md))
or an appended dated section on the existing Plan issue (below).

### Mapping features onto the hierarchy

- **Each feature = one Epic** under the plan root. Decompose into Stories only when
  the feature has evident sub-work; a trivial feature may be a single-story epic.
  Introduce Tasks only when a further sub-tier is evident (unchanged rule).
- **Numbering continues repo-wide (both modes).** The next epic number is the max
  `Epic <N>:` prefix across ALL issues in the repo (open + closed) + 1 (min 1) —
  `resolve-plan-root.ps1` computes it. No duplicate `Epic N` prefixes in one repo;
  `Story N.M` inherits that uniqueness, and title-based ensure-matching stays
  unambiguous across plans. Never restart numbering at 1 for a new campaign.
- **Milestone convention.** Create a milestone **named after the campaign** and
  assign it to each campaign epic and all its descendants (this also satisfies the
  DryRun milestone assertion).

> **Terminology collision, campaigns edition.** Feature campaigns deliberately do
> **NOT** create or use the **`Phase` Project field** — campaign grouping is the
> plan-body campaign section + the campaign milestone. The Phase field remains
> plan-doc-driven only. Never pass `-Phases`/`-Phase` for a campaign run.

### Campaign derivation rules

- **Name:** the tightest honest theme shared by the features, 2–5 words.
  Calibration: `gRPC Migration`, `Backend Cleanup & Refactor`, `Frontend
  Performance`, `Expand Test Coverage`, `ArgoCD Deployment Conversion`. Truly
  heterogeneous fallback: `Feature Batch: <dominant theme or YYYY-MM>`.
- **Overview:** 3–6 sentences on the campaign's central theme and intended outcome —
  what the feature set collectively achieves and why. No per-feature detail (that
  lives on the epics).
- **Goals:** 2–5 bullets derived from the features.
- **Omit any section with no derivable content** (existing omit-don't-fabricate
  rule). Heavyweight application-plan sections (Tech Stack table, Repository
  layout, Exact package versions, Development Standards) are **never fabricated**
  for campaigns. Existing guards apply unchanged to campaign bodies: the filler
  detector, child-issue list identifiers (`Epic <N>:` / `Story <N>.<M>:` verbatim in
  the Implementation Plan lists), and `assert-no-secrets.ps1`.

### Modes (`DEFAULT_EXISTING_PLAN_MODE`)

Resolve the anchor with `resolve-plan-root.ps1`; the mode applies **only** to
feature-list sources:

| Mode | Behavior |
|---|---|
| `continue-existing` (default) | ≥1 open plan root → attach to the **newest by creation** (log when several). 0 open → create a new wrapper Plan issue (closed plan roots are finished campaigns, never continued). Narrative = appended `## Feature Campaign: <Name> (<UTC date>)` section on the existing Plan body. |
| `new-feature-plan` | Always create a new wrapper Plan issue, even when open plan roots exist. Numbering still continues repo-wide. |

### Appended-section flow (continue-existing, idempotent re-sync)

Fetch the existing Plan body, **replace** an existing `## Feature Campaign: <Name>`
section by heading match, or **append** if absent — never blind-append (a re-run of
the same list must replace, not duplicate):

```pwsh
$anchorJson = & "$Skill/resolve-plan-root.ps1" -Repo $ghrepo -Mode $ExistingPlanMode
$anchor = $anchorJson | ConvertFrom-Json
$epicN = [int]$anchor.NextEpicNumber   # number this campaign's epics from here
if ($anchor.CreatePlan) {
    # render feature-campaign-plan.md with the derived campaign body, then:
    $planNumber = & "$Skill/ensure-issue.ps1" -Repo $ghrepo -Title "Plan: $CampaignName" -BodyFile $planBodyFile -Labels plan
} else {
    # replace-or-append the dated '## Feature Campaign: <Name> (<UTC date>)' section:
    $existingBody = Invoke-Gh api "repos/$ghrepo/issues/$($anchor.PlanNumber)" --jq .body
    $newBody = Merge-CampaignSection -Body $existingBody -Section $campaignSection   # heading-match replace, else append
    $planNumber = & "$Skill/ensure-issue.ps1" -Repo $ghrepo -Title $anchor.PlanTitle -Body $newBody -Labels plan -UpdateBody
}
```

Campaign epics/stories use `epic.md`/`story.md` filled from the feature content
(the per-feature detail lives there, not on the plan body). Pass splatted hashtables
for field assignment; never build integer-keyed lookup maps (existing driver rules).
Concurrent campaigns can race the max-epic scan (read-then-create is not atomic) —
sequence concurrent runs rather than parallelizing them.

### Smoke scenarios (throwaway repo, user-run)

- (a) Feature list on an empty repo → wrapper campaign Plan + epics (numbering from 1).
- (b) Re-run the same list → idempotent: campaign section **replaced**, not duplicated; issues matched by title.
- (c) Second feature list, `continue-existing` → appended dated section on the same Plan root; epic numbering continues repo-wide.
- (d) `new-feature-plan` → a second Plan root; numbering still continues repo-wide.

## Prerequisites

- `pwsh` 7+ and `gh` authenticated with the `project` scope (`$GITHUB_TOKEN` is honored).
- Run everything from the repository root. Preview with `-DryRun` before applying.

## Conventions (must follow)

- **Sub-issues only** for hierarchy (plan→epic→story→task). Never use issue-linked
  task lists for parent/child. Plain checklists inside a body are fine for
  acceptance criteria / sub-steps only.
- **Numbered titles:** `Plan: <Name>`, `Epic <N>: <Name>`, `Story <N>.<M>: <Name>`,
  `Task <N>.<M>.<K>: <Name>`. Keep numbering stable across re-runs.
- **Child-issue list identifiers (mandatory).** When rendering a parent-issue body
  (Plan → epics, Epic → stories, Story → tasks), **every** entry in **any** list
  that enumerates child issues must carry its numeric identifier verbatim:
  `Epic <N>:`, `Story <N>.<M>:`, or `Task <N>.<M>.<K>:`. Plain-text bullets without
  identifiers are **never acceptable** in child-issue lists — this applies to the
  Plan body's *Implementation Plan* section (epics + their stories), the Epic body's
  *Epic Stories* and *Implementation Plan* sections (stories + their tasks), and the
  Story body's *Plan* section (tasks). Acceptance-criteria, validation, and plain
  step checklists *within a single issue* are exempt — those describe steps, not
  child issues. The templates carry `<!-- REQUIRED ... -->` reminders in each such
  section; honor them.
- **Level labels:** `plan` / `epic` / `story` / `task`; plus `P0..P3`, `area/*`.
  Workflow state lives in the Project **Status** field, not labels.
- **Milestones** = conceptual work groups (e.g. `POC`, `MVP`, `UI`, `Server`),
  assigned to the epic **and all its descendants**.
- **Phases** are optional; only create the Phase field/values if the plan uses them.
- Bodies come from the templates in
  [`assets/templates/`](./assets/templates/)
  (`application-plan.md`, `feature-campaign-plan.md`, `epic.md`, `story.md`,
  `task.md`) — fill placeholders, then
  pass the result to `ensure-issue.ps1` via `-BodyFile`.

## Body composition specification

The templates in `assets/templates/` are skeletons — their placeholders must be
filled with **plan-derived content**, not agent-composed boilerplate. The rules
below govern what lands where. They are enforced at DryRun time (see the filler
detector in
[`references/driver-composition.md`](./references/driver-composition.md)). The single root cause of
the prior content-fidelity defects was that the skill left body composition to
inference, and inference defaulted to filler; this section makes the contract
explicit.

### Plan-content transfer manifest

Each row declares where a class of plan content **must** land, and at what
fidelity. When the plan **does not** contain content for a row, **omit** the
corresponding issue section entirely — do not fabricate placeholder content.

| Plan element | Target issue | Fidelity |
|---|---|---|
| Per-task inline code/config snippet (a `Reference:` block, or equivalent) | Story `Plan → Implementation approach → Reference (from plan T-x.y)` | **Verbatim** in a fenced code block with matching language tag |
| Per-task agent note (e.g. ⚠️ warning, "verify before committing") | Story `Implementation Notes` | **Verbatim** |
| Per-task out-of-scope items | Story `Scope → Out of Scope` | **Omit** the subsection if the task has none specific |
| Cross-cutting mandatory rules / operating principles | Plan body `Development Standards → Mandatory rules` | **Verbatim** (one canonical copy) |
| Naming & code conventions | Plan body `Development Standards → Naming & code conventions` | **Verbatim** |
| Definition of Done | Plan body `Development Standards → Definition of Done` | **Verbatim** |
| Handoff checklist / escalation protocol | Plan body `Development Standards` (last two sub-sections) | **Verbatim** |
| Exact package-version table | Plan body `Exact package versions` | **Verbatim table** — not summarized into prose |
| Repository file tree | Plan body `Repository layout` | **Verbatim tree** — not summarized into a 3-line summary |
| Risk-register rows | Epic `Risk Mitigation Strategies` (relevant rows only) + Plan body full table | Split: each epic gets only the rows whose mitigation references a task within it |
| Prompt-text catalog (if the plan includes one) | The stories whose `Plan` section implements the corresponding prompt | **Verbatim** inside the story's `Reference` fenced block |
| Parallel-execution map / task groups | Plan body (optional summary) | Summarized; blocked-by edges already encode the dependencies structurally |
| Per-epic technology subset | Epic `Brief Technology Stack` | Only rows applicable to that epic; remove the rest |
| Feature-list theme (derived campaign overview) | Campaign Plan body `Overview` | **Derived**: 3–6 sentences on the shared theme and intended outcome; no per-feature detail |
| Features (feature-list source) | Campaign Plan body `Goals` + `Implementation Plan` entries | Each feature = one `Epic <N>:` entry (with its `Story <N>.<M>:` entries when decomposed); numbering continues from `NextEpicNumber` |
| Per-feature detail (feature-list source) | Epic bodies (`epic.md` filled from feature content) | Feature-specific overview/goals/stories live on the epic — never on the campaign Plan body |

### Filler prohibition

No two sibling issues (stories under the same epic, or epics under the same
plan) may share a body section whose text is **byte-identical** unless that
section is genuinely common cross-cutting content that has been placed
canonically on the Plan body. Concretely:

- A story's `Plan`, `Implementation Notes`, `Validation Commands`, `Out of Scope`,
  and `Test Strategy` sections must differ in substance from the same sections
  in any sibling story. "Implement per the AC…" / "Add tests…" / "dotnet build
  exit 0" / "CancellationToken / Never hardcode secrets" — these are filler
  when they repeat across stories.
- An epic's `Brief Technology Stack` and `Risk Mitigation Strategies` must
  differ across epics. A 5-line stack block or a 2-row risk table that
  appears in every epic is filler (and, in the case of cross-epic stack
  bleed like "AI/Runtime: …" on a non-AI epic, actively wrong).

When a section has nothing task- or epic-specific to say, **omit the section
entirely** rather than paste boilerplate. The DryRun filler detector (see
[`references/driver-composition.md`](./references/driver-composition.md))
makes this load-bearing: a section body byte-identical across ≥ 3 sibling
issues throws at preview time.

### Canonical cross-cutting content

Cross-cutting rules (mandatory rules / operating principles, naming
conventions, DoD, handoff checklist, escalation protocol, exact versions,
repository layout) live **once** on the Plan body's `Development Standards`,
`Exact package versions`, and `Repository layout` sections. They are **not**
copied into individual story or epic bodies. If a story needs to reference
them, it links to the Plan issue by number (`Part of #<plan-issue>`) — it does
not re-paste the rules.

## Orchestration steps

Work top-down. Always do a `-DryRun` pass first, show the plan, then apply.
All scripts below live in this skill's `scripts/` directory.

**Resolve inputs first.** If `$ghrepo` is not given, derive it from the current
repo (see [Inputs](#inputs)). If no plan source is named, resolve it non-interactively
from `plan_docs/` per the plan-doc set convention above — classify by filename role,
use the primary plan as the node source, and fold the rest into the Plan body as
supporting context. If the supplied (or described) source is a feature list, the
[Feature-list plan source](#feature-list-plan-source-feature-campaigns) flow applies
instead. The only hard stop is an empty/missing `plan_docs/` with no plan source
supplied; everything else resolves automatically. **Do not prompt the user to choose
between plan docs.**

**Initialize the forensic logfile first.** At the very top of the composed driver
script — before any GitHub call — initialize the per-run logfile so every subsequent
operation (every `Invoke-Gh`, every `Write-Step`/`Write-Ok`/`Write-Skip`/`Write-DryRun`,
across every dot-sourced op script) is mirrored into it for post-execution forensics:

```pwsh
. (Join-Path $Skill 'common.ps1')
$slug = ($ghrepo -split '/')[-1]   # e.g. 'gap-miner-v2-delta12'
$logPath = Initialize-LogFile -RepoSlug $slug -RepoRoot (Get-Location) -Repo $ghrepo
Write-Step "Logging to: $logPath"
```

`Initialize-LogFile` writes a header block recording the repository identity, the
absolute working-copy path, the checked-out git rev + ref, the script directory, and
the OS/PowerShell version. The path is carried in `$env:GHIT_LOG_FILE`, so every op
script (each with its own `$script:` scope) writes to the same file without needing
the path passed in. The file lands at `<repo-root>/gh-init-<slug>-<UTC-timestamp>.log`
and is covered by `.gitignore` (`gh-init-*.log`).

1. **Resolve the plan anchor** (feature-campaign runs only — plan-doc runs match
   their plan issue by title and skip this): call
   `resolve-plan-root.ps1 -Repo $ghrepo [-Mode $ExistingPlanMode]` and capture its
   single JSON line (`ConvertFrom-Json`). `CreatePlan`/`PlanNumber`/`PlanTitle`
   decide whether the run creates a wrapper Plan issue (template
   `feature-campaign-plan.md`) or appends a campaign section to the existing root
   (see *Feature-list plan source*); `NextEpicNumber` is the first epic number this
   run may assign.
2. **Parse the plan** into a tree of nodes (plan, epics, stories, tasks) with the
   numbered titles above, plus per-node labels, milestone, phase, priority, estimate,
   and any blocking dependencies. For feature-campaign runs, number the epics from
   the resolved `NextEpicNumber` (repo-wide continuation).

   **Canonical node schema** (assert presence before rendering — an omitted field
   produces empty titles/milestones silently otherwise):
   - `Level` (`plan`/`epic`/`story`/`task`)
   - `Title` (the full numbered title, e.g. `Story 1.1: Bootstrap`) **or** the parts to
     build it (`N`/`M`/`K`, `Name`)
   - `Labels`, `Milestone`, `Priority`, `Phase` (if used)
   - `BodyFile` (after rendering), `Prereqs` (array of sibling keys, story/task level)
3. **Labels:** `ensure-labels.ps1 -Repo $ghrepo`.
4. **Milestones:** for each conceptual group, `create-milestones.ps1 -Repo $ghrepo -Titles <name> -SkipExisting`.
5. **Project + fields:** `ensure-project.ps1 -Owner <owner> -Repo $ghrepo [-Phases <p1,p2>]`.
   Capture the **project number** from stdout (`$Proj = & ensure-project.ps1 ...`); in
   `-DryRun` it is `$null` (the project is not created, so nothing is emitted).
6. **Create issues** (top-down) with `ensure-issue.ps1`, filling the matching template
   into a temp file and passing `-BodyFile` — `application-plan.md` for plan-doc
   roots, `feature-campaign-plan.md` for campaign roots, and `epic.md`/`story.md`/
   `task.md` filled from the feature content for campaign epics/stories/tasks.
   Capture each printed issue **number**:
   - plan → epics → stories → tasks; apply the level label and (for epics + descendants) the milestone.
7. **Link sub-issues** with `link-sub-issue.ps1 -ParentNumber <parent> -ChildNumber <child>`
   for every parent/child edge.
8. **Set board fields** with `set-project-fields.ps1` for each issue: `-Level`,
   `-Priority`, `-Phase` (if used), `-Estimate`, `-Status` (default `Todo`).
9. **Dependencies:** for each "blocked by" edge, `set-dependency.ps1 -IssueNumber <blocked> -BlockedByNumber <blocker>`.
10. **Views + Status options:** `ensure-project.ps1` already created them
    (Status options via `updateProjectV2Field`; the four views via the Projects v2
    REST view API, deleting the leftover default "View 1"). If the target's API
    surface lacks these (e.g. GHES), the script prints manual instructions —
    relay those to the user only when they appear.
11. **Signal completion:** on a successful **apply** run (never in `-DryRun`, never after a
    partial/failed run), apply the `gh-issue-tracking:init-success` label to the **plan
    root this run attached to** — the plan-level issue created this run **or** the
    existing plan root continued this run (`gh issue edit` is idempotent for an
    already-labeled existing root). This label is the orchestration hand-off signal —
    a downstream orchestrator matches it to learn the hierarchy is initialized and
    ready. The label was ensured by step 3, so apply it directly:
    ```pwsh
    # $planNumber = the Plan issue number created/continued this run; $ghrepo = target repo.
    # Guard on success: only the final action of a fully-applied (non-DryRun) run.
    & gh issue edit $planNumber --repo $ghrepo --add-label 'gh-issue-tracking:init-success'
    ```
    A plan root is required: if the run attached to no plan root (no apply happened,
    or the run was `-DryRun`), skip this step. If the label apply fails, log a warning
    but do not fail the run — the hierarchy itself is already complete.

## Delegation performance (batching)

When composing the driver, **read
[`references/driver-composition.md`](./references/driver-composition.md) first** — it
carries the full rules, rationale, and code blocks distilled from forensic runs.
The non-negotiables (each elaborated in the reference):

- **Compose a single orchestration script** — never one op script per LLM turn
  (measured at ~77 minutes for ~40% of a 30-issue run); loop the ops in dependency
  order with a small sleep between REST-mutating calls.
- **Isolate scratch under `/tmp/kilo/<repo-slug>/`** — never loose in a flat `/tmp/kilo/`.
- **Splat hashtables** for `set-project-fields.ps1` (array splatting misbinds
  parameters), and **never build integer-keyed lookup maps** — use a `switch`
  function or `[string]`-keyed `@{}`.
- **DryRun must assert** (before any `gh issue create`): non-empty titles/milestones,
  no filler (no `##`/`###` section byte-identical across >= 3 sibling issues), and no
  secrets (`assert-no-secrets.ps1` over every rendered body).
- **Stream driver liveness:** never redirect the apply to a file-only sink (use
  `Tee-Object`, never `> log 2>&1`) and chunk the apply per epic so no single call
  outlives the ~300 s idle window.
- **Never ship a `$Num`/`$num` pair** — PowerShell variable names are
  case-insensitive; use distinct names and audit the driver for case collisions.

## Idempotency & re-runs

The scripts match existing labels/milestones/fields/issues (by numbered title)/links
and skip or update rather than duplicate. Re-run this skill after editing the plan to
sync additions and changes. Keep titles/numbers stable so matches hold.

## Definition of done

Completion = **closing** a sub-issue (parent progress rolls up automatically). Use the
Project **Status** field for in-flight state. In-issue checklists are informational only.

## Out of scope

The separate issue-implementation skill (current-issue selection / ordering) is
deferred — see the plan's "Out of Scope". **Defects/bugs** are also deferred as a
product decision (templates, labels, and selection semantics all need designing).
The old technical blocker is gone: extending the `Level` single-select after field
creation is now automatable (`updateProjectV2Field` with `singleSelectOptions`,
the same mechanism `ensure-project.ps1` uses for the built-in Status field).

## Known limitations

Decide with these in mind up front (not only at script-reference time):

- **Project views are automated** (github.com, since the 2026 REST view API + GraphQL view mutations). `ensure-project.ps1` creates **By Phase** (table, grouped by Phase when `-Phases` is used), **By Status** (board grouped by Status), **By Epic** (board grouped by the built-in Parent-issue field), and **Current work** (table filtered to open, unblocked items), then deletes the leftover default "View 1" (create happens first — GitHub refuses to delete a project's last remaining view). Preferred path is the REST view API (one call: layout + grouping + filter); on user-owned projects the REST path 404s today, so it falls back to GraphQL `createProjectV2View` + `updateProjectV2View(filter)` — which cannot set board **grouping**, so grouped views created that way carry a one-time warning with the exact grouping to click. On targets with neither API (e.g. GHES) it prints the manual click-path and still exits green.
- **Built-in `Status` options are automated.** `updateProjectV2Field` with `singleSelectOptions` appends the missing options (`In Review`, `Blocked`); the merge re-sends existing option **ids** (replace-all semantics — omitting an id clears item values) and is otherwise purely additive, so platform/user styling survives. If the read shows options without ids (defensive) or the mutation fails, the script prints the manual note instead.
- **GitHub database IDs exceed Int32.** Global issue DB IDs exceed `Int32.MaxValue` (2,147,483,647); `Get-IssueDbId` casts to `[long]`, so `link-sub-issue.ps1` and `set-dependency.ps1` work against modern repos (fixed in this release).

## Validation

Run the Pester suite for the scripts, and the user-run end-to-end smoke test against a
throwaway repo — both documented in
[`scripts/README.md`](./scripts/README.md).

# Plan: gh-issue-tracking-init — Automate Project Views & Status Field Options

Status: IMPLEMENTED (2026-11-03 — see "As-built deviations" at the end)
Date: 2026-11-03
Skill under change: `.agents/skills/gh-issue-tracking-init/`

## Problem

The skill documents two GitHub Platform limitations that no longer exist. Both steer
agents away from capabilities that now work, and both force a manual UI step into an
otherwise fully-autonomous skill run:

| # | Documented limitation | Where | Reality (verified 2026-11) |
|---|---|---|---|
| 1 | "Project views are not automatable. `gh`/API has no supported 'create view' operation" | SKILL.md:553, README.md:37+212-216, scripts/README.md:37, ensure-project.ps1:19, references/gh-issue-tracking-plan.md (step 9 / views section) | REST view-create endpoints (API version `2026-03-10`) + GraphQL `createProjectV2View` / `updateProjectV2View` / `deleteProjectV2View` (schema changes 2026-07-28 and 2026-07-30, now in the official GraphQL reference) |
| 2 | "Built-in `Status` options are limited. `gh` cannot add options to an existing single-select field" (initial set `Todo / In Progress / Done`; `In Review`/`Blocked` added in UI) | SKILL.md:554, README.md:38, ensure-project.ps1:165 | `updateProjectV2Field` accepts `singleSelectOptions` — including on the built-in Status field (`PVTSSF_…`) — with documented preserve-by-id semantics |

A third, dependent claim is also void: SKILL.md:543-547 defers the `defect` level
because "extending the Project `Level` single-select *after* field creation …
`gh`/API cannot do (options are only settable at field creation)". Limitation 2's
fix removes that technical blocker (whether to ship `defect` remains a separate
product decision — out of scope here, but the doc rationale must be corrected).

## Evidence base (research, 2026-11-03)

First-hand verification from this machine:

```
$ gh api graphql (introspect Mutation) | grep -i projectv2view
createProjectV2View
deleteProjectV2View
updateProjectV2View

$ gh api graphql (introspect UpdateProjectV2FieldInput).inputFields
clientMutationId, fieldId, name, singleSelectOptions, multiSelectOptions, iterationConfiguration
```

Auth: active `gh` token has `project` scope (required minimum for `gh project` and
these endpoints) — no new credential work needed.

Documented sources:

- GraphQL schema changelog 2026-07-28: view mutations added;
  2026-07-30: `configuration.visibleFieldIds` added to view create/update.
- GraphQL Projects reference: `CreateProjectV2ViewInput` (projectId, name, layout,
  configuration — **no `filter` on create**); `UpdateProjectV2ViewInput` (viewId,
  name, layout, filter, configuration); `ProjectV2SingleSelectFieldOptionInput.id` —
  *"Include this to preserve the option's identity during updates, preventing item
  field values from being cleared"*; `UpdateProjectV2FieldInput.singleSelectOptions` —
  *"Empty input is ignored, provided values overwrite existing options, and existing
  options should be fetched for partial updates."*
- REST reference "REST API endpoints for Project views":
  `POST /orgs/{org}/projectsV2/{project_number}/views` and
  `POST /users/{user_id}/projectsV2/{project_number}/views`; body supports `name`,
  `layout` (`table|board|roadmap`), `filter`, `visible_fields`, `sort_by`,
  `group_by`, `vertical_group_by` in **one call**. Header
  `X-GitHub-Api-Version: 2026-03-10`.
- gh CLI ≤2.97 has **no** `gh project view-*` or `field-update` subcommands
  (cli/cli #14306 requests view-list) → transport is `gh api` (REST) +
  `gh api graphql` (mutations), both already used by the skill's scripts.
- Community-verified (2026-04): single `updateProjectV2Field` mutation with
  `singleSelectOptions` succeeded on the built-in Status field via a plain PAT with
  `project` scope (board-superpowers #13); replace-all semantics and preserve-by-id
  recovery documented in AMOA kanban references.
- Official GitHub MCP server v1.10.0 (2026-08) ships view lifecycle tools — confirms
  platform direction; not adopted here (adds a dependency for what `gh api` does).

Rejected alternatives (researched): GitHub App / Probot (same API surface, deploy
cost, no added capability), GitHub MCP server (dependency for what `gh api` does),
undocumented `/memexes/` internal API (unsupported; github/gh-aw shipped then
removed undocumented view mutations after silent failures), browser automation
(brittle, needs logged-in session), `copyProjectV2` template route (copies views but
creates a whole new project — can't retrofit the ensured project; viable only as a
GHES-adjacent fallback, not needed).

## Goal

A skill apply-run autonomously creates the four Project views (**By Phase, By
Status, By Epic, Current work**) and the full 5-option Status field (**Todo /
In Progress / In Review / Blocked / Done**), idempotently, with a graceful fallback
to the current printed-click-path behavior when the APIs are unavailable (e.g.
GHES, lagging deployment). Existing item field values must survive the Status
options update.

## Non-goals

- GHES support/backports (fallback behavior only).
- Shipping the `defect` level (unblocked technically; separate decision — only the
  stale doc rationale is corrected here).
- Built-in Project workflow automation config (still UI-only; untouched).
- View reordering/position (no API; unchanged).
- Multi-select / iteration field config (schema supports it; no skill need yet).

## API contracts the implementation will use

### Status options (GraphQL via `gh api graphql`)

```graphql
# 1. Read (fetch existing options WITH ids)
query { userOrOrg → project(number: N) {
  field(name: "Status") { ... on ProjectV2SingleSelectField { id options { id name } } } } }

# 2. Mutate — full replacement list; existing entries MUST keep their id
mutation { updateProjectV2Field(input: {
  fieldId: "PVTSSF_…"
  singleSelectOptions: [
    { id: "<existing>", name: "Todo",        color: GRAY,   description: "" }
    { id: "<existing>", name: "In Progress", color: YELLOW, description: "" }
    { id: "<existing>", name: "Done",        color: GREEN,  description: "" }
    { name: "In Review", color: YELLOW, description: "Awaiting review" }
    { name: "Blocked",   color: RED,    description: "Blocked by another issue" }
  ] }) { projectV2Field { ... on ProjectV2SingleSelectField { options { id name } } } } }
```

Gotchas (all verified): replace-all semantics — omit an existing option's `id` and
its identity regenerates, **clearing item values**; `color` is an ALL-CAPS enum
(GRAY/GREEN/YELLOW/RED/…); `description` is required (empty string OK); mutation
takes only `fieldId` (passing `projectId` errors).

### Views

```
# Create (REST, one call carries filter + grouping + sort + visible fields)
gh api -X POST /orgs/{org}/projectsV2/{N}/views \
  -H "X-GitHub-Api-Version: 2026-03-10" \
  -f name="By Status" -f layout=board -F vertical_group_by[]="<Status field db id>"

# User-owned projects: /users/{user_id}/… where user_id is the NUMERIC id
# (resolve via: gh api users/{login} --jq .id) — org path uses the login.

# Rename/re-filter the default "View 1" (GraphQL create has no filter; REST has no update)
mutation { updateProjectV2View(input: { viewId: "…", name: "By Phase", filter: "…" }) { projectV2View { id } } }

# Read for idempotency
query { … project(number: N) { views { nodes { number name layout } } } }
```

Desired-state model:

| View | Layout | Configuration |
|---|---|---|
| By Phase | table | default "View 1" renamed via `updateProjectV2View` (no leftover default view) |
| By Status | board | `vertical_group_by` = Status field db id |
| By Epic | board | `vertical_group_by` = Epic field db id (grouping field; see open questions) |
| Current work | table | `filter: "state:open -label:blocked"` (or active-milestone scope) |

## Work items

### W1 — Status options merge (extend `ensure-project.ps1`)

New `Ensure-SingleSelectOptions` helper (dot-sourced in ensure-project.ps1;
reusable later for `Level`):

1. Query Status field options with ids (query above).
2. Merge: keep existing options **with ids** (order preserved); append desired
   missing-by-name options (`In Review`, `Blocked`); if already complete → skip
   (idempotency, matches ensure-* contract).
3. Mutate with the full list; re-query to verify.
4. `-DryRun` prints the option diff without mutating; apply path keeps the existing
   ~500 ms inter-call sleep (secondary rate limits).

### W2 — View creation (extend `ensure-project.ps1`)

Runs after W1 (board grouping needs the field ids). Steps:

1. Read `project.views` once; match desired views by name (case-insensitive).
2. Missing → REST create per desired-state model above.
3. Default view handling: if a view named "View 1" (or the positional default with
   default name) exists and "By Phase" is missing → `updateProjectV2View` rename
   (+ optional filter) instead of create+leftover.
4. Capability probe + fallback: on 404/405 from the REST view endpoint or schema
   error on the GraphQL mutation, print the existing four-view click-path text and
   continue with a warning (exit 0) — a GHES run stays green, matching today's
   behavior.

### W3 — Documentation updates (surgical; all stale claims)

- SKILL.md:553 — views bullet → automatable; names the mechanism + fallback condition.
- SKILL.md:554 — Status bullet → options merge; full 5-option set.
- SKILL.md:245-246 (step 9) — "Views: created by `ensure-project.ps1` (falls back
  to printed instructions when the API is unavailable)".
- SKILL.md:543-547 (Out of scope / defect) — remove the "API cannot extend options"
  rationale; keep deferral as a product decision with corrected note.
- README.md:37-38 and 212-216 — mirror SKILL.md changes.
- scripts/README.md:37 — same.
- ensure-project.ps1:19 (header comment) and the line-165 Write-Skip message.
- references/gh-issue-tracking-plan.md — views/status rows and line ~134
  ("creates the Project (fields, options, views)").

### W4 — Tests + validation

- Pester (repo conventions: one `BeforeAll` per `Describe`; no markdown backticks
  inside double-quoted here-strings):
  - Merge logic: preserves ids; no-op when current; appends only missing; DryRun
    emits diff and performs zero mutations (mocked `gh`).
  - Views: create payload shape per view (layout/grouping/filter); rename-default
    path; skip-when-existing; fallback path on 404 (exit 0 + click-path text).
  - Reuse the existing mocked-`gh` stub pattern from
    `scripts/tests/EnsureIssueAndProject.Tests.ps1`.
- `./validation.ps1` green; coverage stays > 85% (repo gate).
- End-to-end on a throwaway test repo: DryRun preview → apply → assert via API
  (4 views, 5 Status options) → re-run asserts zero changes → set an item's Status
  → re-run options merge → assert the item's value survived.

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| Replace-all options wipes item Status values | Always fetch + re-pass existing ids; post-mutation verification step; e2e test asserts value survival |
| New APIs absent (GHES / lagging deploy) | Runtime capability probe; graceful fallback to today's printed instructions; never hard-fail the run |
| Numeric `user_id` quirk on user-owned REST path | Resolve via `gh api users/{login} --jq .id`; org path (common case) unaffected |
| GraphQL view create lacks `filter`; REST lacks update | REST for create (has filter+grouping), GraphQL for rename/filter/delete — the pair covers CRUD |
| Default view not named "View 1" on re-runs / already renamed | Match by name via `project.views`; rename only when "By Phase" is missing |
| Roadmap-layout `visible_fields` ignored / grouping-field exclusions (Title, Reviewers, Linked PRs, Sub-issues progress, Tracked by, Tracks) | Desired views use only Status/Epic grouping (allowed single-select fields); no roadmap views |

## Done when

- [ ] Apply-run on a fresh test repo creates 4 views + 5-option Status autonomously; re-run is a no-op
- [ ] An item's existing Status value survives the options merge (test-asserted)
- [ ] Forced API failure (mocked 404) falls back to printed click-path, exit 0
- [ ] All doc locations in W3 updated; no stale "not automatable" claims remain
- [ ] `./validation.ps1` green; coverage > 85%

## Open questions (non-blocking)

- Exact `Current work` filter syntax (`state:open -label:blocked` vs
  milestone-scoped) — decide during W2 against a live board; default to the simpler
  filter.
- Whether "By Epic" groups by the Epic single-select field or by sub-issue parent —
  the plan reference says "grouped by parent epic"; sub-issue grouping is not an
  API grouping field, so Epic-field grouping is the implementable interpretation.

## As-built deviations (live e2e findings, 2026-11-03)

Implemented per plan with these evidence-driven adjustments, all verified live
against a user-owned scratch project (#76, fully restored afterwards):

1. **"By Epic" groups by the built-in `Parent issue` field** (open question
   resolved): the live field list shows `Parent issue` as a real field with a
   database id — API-groupable — so boards get one column per parent epic.
2. **User-owned projects have no REST view API today** — every
   `/users/.../projectsV2/{n}/views` form 404s (numeric id, login, node id,
   singular `/user/`). Implemented the planned REST create as the *preferred*
   path (org projects) with a **GraphQL fallback**
   (`createProjectV2View` + `updateProjectV2View(filter)`), which cannot set
   board grouping — grouped views created via fallback emit a one-time warning
   naming the grouping to set in the UI.
3. **View deletion ordering matters**: `deleteProjectV2View` refuses to destroy
   a project's *last* remaining view ("Cannot destroy the last remaining view").
   The implementation creates "By Phase" before deleting "View 1", so the
   invariant always holds.
4. **`gh api graphql` typed-field quirk**: an `Int!` variable passed via `-f`
   is rejected ("provided invalid value"); `-F` (raw) works. String variables
   work via `-f`.
5. **Status merge is purely additive** (stronger than planned): existing
   options are echoed back verbatim (id + platform color/description — e.g.
   Todo/GREEN, Done/PURPLE), only missing canonical options get canonical
   styling, unknown extras are preserved at the end. Re-runs are exact no-ops
   and never restyle a user's board.
6. **Helper naming**: W1's planned `Ensure-SingleSelectOptions` helper shipped
   as `Ensure-StatusOptions`, defined inline in `ensure-project.ps1` (not
   dot-sourced).
7. **Review hardening** (post-review fixes, same day): the GraphQL view
   fallback is gated on REST *unavailability* (HTTP 404/405 captured from gh
   stderr) — transient failures (429/5xx/422) route to the manual list instead
   of permanently degraded grouping-less views; a filter-update failure after
    a successful GraphQL create warns instead of printing duplicate-creating
    manual instructions; the views read is paginated (`first: 50` + cursor
    loop) so view-heavy projects cannot produce duplicate creates; option
    color/description reads are null-guarded (null color defaults to GRAY).
 8. **PR review round 2** (same day): the GraphQL read now paginates the
    `fields` connection with the same `pageInfo` cursor loop as `views` (a
    project with >50 fields could previously hide Status/Phase/Parent issue
    past page 1, silently degrading grouping — unrepaired on re-runs since
    existing views are skipped by name); `Get-OptionProp` also rejects empty
    strings (an API `""` color would emit the invalid literal `color: ,`);
    `resolve-plan-root.ps1` reads `number` through the same
    `PSObject.Properties` StrictMode guard as `title`/`created_at`; the test
    mock logs GraphQL reads (`READ ` prefix) and the fallback test asserts
    exactly one read; the view-create-failure test asserts the `View 1`
    delete its title names; docs corrected (source-class count, two dangling
    `above` cross-references from the SKILL.md split, stale verification
    counts, memory factual errors, `exisintg`→`existing` filename typo via
    `git mv`).

Verification: 20 new Pester tests (`EnsureProjectViews.Tests.ps1`) + full suite
263/263, coverage 95.28% at delivery (95.20% after the PR-review round below),
`validation.ps1` all green; live apply + idempotent
re-run + option-id preservation confirmed on the scratch project.

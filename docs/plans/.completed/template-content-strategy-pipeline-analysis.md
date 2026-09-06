# Plan — Revise template-content-strategy.md with cloning-pipeline findings

**Date:** 2026-07-19
**Target files:** `docs/plans/.deferred/template-content-strategy.md`, (possibly) `AGENTS.md`

---

## Analysis Report (for the human)

The existing strategy doc's two-class model is sound and the work items are
directionally correct, but it was written without knowledge of what the actual
cloning pipeline already does. I examined:

- `nam20485/workflow-launch2/scripts/create-repo-from-slug.ps1` (thin wrapper)
- `nam20485/workflow-launch2/scripts/create-repo-with-plan-docs.ps1` (main script)
- `nam20485/workflow-launch2/scripts/repo-functions.ps1` (helpers: `Update-TemplatePlaceholders`, `Assert-NoTemplatePlaceholdersRemaining`, `Copy-PlanDocs`, etc.)
- `nam20485/workflow-launch2/scripts/trigger-project-setup.ps1` (post-creation orchestrator kick-off)
- `intel-agency/gap-miner-v2-delta12` (real cloned instance created 2026-07-19)

### Key findings

1. **W1 step 4 is already handled; W1 step 5 is broken.**
   - **Step 4 (seed plan docs):** `Copy-PlanDocs` in the main script copies
     `plan_docs/<slug>/*` into `plan_docs/` on the clone. ✅
   - **Step 5 (build hierarchy):** the `-TriggerProjectSetup $True` path (default)
     currently calls `trigger-project-setup.ps1`, which dispatches
     `/orchestrate-dynamic-workflow $workflow_name = project-setup` — an
     orchestrator workflow ported from a prior template that is largely
     incompatible with `agent-context`'s new structure. The user passes
     `-TriggerProjectSetup $False` to bypass it entirely. **Needs replacement:**
     the trigger should invoke `/gh-issue-tracking-init` directly (no args — its
     defaults resolve to the current repo + seeded `plan_docs/`, exactly the
     post-clone state).

2. **W1 steps 1–3 are NOT handled** — verified in gap-miner-v2-delta12:
   - `.agents/memory.md` carries the template's entire `Current Activity` block
     (including the content-strategy project itself!), plus `Completed Work Items`,
     `Decisions`, and `Remember To Do`. All Class 2. All wrong in a clone.
   - `docs/plans/.completed/*.md` and `docs/plans/.deferred/*.md` transfer
     verbatim, including the template's own plans (e.g. this strategy doc, the
     `gh-issue-tracking-plan-source-resolution`, etc.).
   - `docs/plans/.completed/run-issues-review/` Gap Mining review artifact
     survives if present at clone time.

3. **NEW bug: AGENTS.md semantic rewrite silently fails.** The script targets
   `$oldLabel = '**GitHub template repo**'` but the current template AGENTS.md
   line 5 reads `**upstream GitHub template**`. The literal mismatch causes the
   rewrite to silently skip ("skipped (already updated)"). Result: the cloned
   instance's AGENTS.md still declares "*this repository … is the upstream GitHub
   template*" — semantically wrong for a downstream instance. Generic name
   replacement did land (`intel-agency/agent-context` → the clone name), but the
   role label was not flipped.

4. **Where the reset should live (resolved).** The open question in the strategy
   doc ("which workflow owns it — `orchestrate-new-project` /
   `orchestrate-project-setup`?") is answered by the pipeline itself: the
   Class-2 cleanup belongs in the **external creation script**
   (`create-repo-with-plan-docs.ps1`). Rationale:
   - It already owns placeholder replacement and the (partially-broken) AGENTS.md
     rewrite — same kind of "post-clone cleanup" operation.
   - It has full local filesystem access to the clone before the first commit.
   - It runs before any follow-up orchestrator/skill trigger, so cleanup must
     precede seeding and hierarchy-building.
   - The `gh-issue-tracking-init` skill then sees a clean instance with
     `plan_docs/` already seeded and builds the hierarchy.
   Adding the reset in the post-creation trigger would be late (it operates via
   GitHub Issues/PRs on a repo that has already been pushed with Class-2 content).

5. **W3 marker convention resolved.** Well-known paths suffice —
   `.agents/memory.md`, `docs/plans/.completed/`, `docs/plans/.deferred/`, and a
   fixed `run-issues-review/` subtree pattern. No per-file markers needed. The
   script can hard-code these paths, same as it already does for `AGENTS.md`.

6. **W2 back-flow discipline unchanged.** Still an organizational-process
   discipline, not something the script automates.

7. **Skeleton memory source (resolved).** The strategy doc's open "ship a blank
   `memory.md` under `assets/` vs. emit inline" question: **emit inline in the
   script.** Keeps the creation pipeline self-contained; no need to add an
   `assets/` directory to the template that serves no purpose in the template
   itself (it would be Class 1 but with no template-local consumer).

### What I recommend implementing

The implementation work is all in the external repo
(`nam20485/workflow-launch2`), except for one small change in this template
repo:

**In `nam20485/workflow-launch2/scripts/create-repo-with-plan-docs.ps1`** — add,
between the `Copy-PlanDocs` step and the placeholder-replacement step (order
matters: delete first, then replace):

  - **W1.1 Reset memory:** delete `.agents/memory.md` and write a blank skeleton
    inline (section headers only, empty Current Activity).
  - **W1.2 Clear template plans:** delete all `*.md` files under
    `docs/plans/.completed/` and `docs/plans/.deferred/` (preserve the lifecycle
    directories themselves).
  - **W1.3 Remove foreign artifacts:** delete the entire
    `docs/plans/.completed/run-issues-review/` subtree (or, more generally, any
    subdirectory under `.completed/` whose name ends in `-review/`).
  - **W1.4 (already done):** `Copy-PlanDocs` — keep as-is.
- **W1.5 (BROKEN — needs replacement):** `-TriggerProjectSetup $True` currently
    dispatches `/orchestrate-dynamic-workflow $workflow_name = project-setup` via
    `trigger-project-setup.ps1`. This orchestrator was ported from a prior
    template and is incompatible with `agent-context`'s new structure (the user
    already bypasses it with `-TriggerProjectSetup $False`). Replace the trigger
    body so it creates a dispatch issue invoking `/gh-issue-tracking-init`
    directly (no args — its defaults resolve to the current repo + seeded
    `plan_docs/`). The `$TriggerProjectSetup` parameter name becomes stale and
    should be renamed (e.g. `$TriggerHierarchyInit` or `$TriggerTrackingInit`)
    to reflect the new target.

**In `nam20485/workflow-launch2/scripts/create-repo-with-plan-docs.ps1`** — fix
the AGENTS.md rewrite anchor:

- Change `$oldLabel = '**GitHub template repo**'` → the text that actually
    appears in the template AGENTS.md, or (more durable) anchor on the full first
    paragraph and rewrite it with clone-aware wording.

**In this template repo (`intel-agency/agent-context`):**

- Update `docs/plans/.deferred/template-content-strategy.md` with the new
    *Cloning pipeline capabilities* and revised *Current state* sections (text
    provided below under "Implementation tasks").
- Update the template AGENTS.md first-paragraph wording so the script's anchor
    matches deterministically (preferred), **or** update the script's `$oldLabel`
    literal to match the current AGENTS.md wording (cheaper but fragile).

### Implementation task list (ordered)

1. **Decide the rewrite-anchor fix strategy** — choose between:
   - **(a)** Change the template AGENTS.md first paragraph to include the literal
     `**GitHub template repo**` somewhere the script can anchor. More durable
     because the script's anchor stays stable.
   - **(b)** Change the script's `$oldLabel` to match the current AGENTS.md
     literal (`**upstream GitHub template**`). Cheaper but fragile: any future
     reword in AGENTS.md breaks the rewrite again.
   **Recommendation: (a).** The template AGENTS.md is the authoritative source,
   and we control it; adjusting it to include a stable anchor the script can
   target is cheaper long-term than chasing rewording in the script.
2. **Implement W1.1–W1.3 in the creation script** — add the cleanup steps in
   `create-repo-with-plan-docs.ps1`, ordered as: W1.3 (foreign artifacts) →
   W1.2 (template plans) → W1.1 (memory reset), all BEFORE `Copy-PlanDocs` and
   placeholder replacement, so replacement doesn't touch files we're about to
   delete.
3. **Fix the AGENTS.md rewrite anchor (W1.4)** — apply the strategy chosen in
   step 1.
4. **Replace the broken post-creation trigger (W1.5):**
   - In `trigger-project-setup.ps1` (or a replacement script), change the
     dispatch-issue body from:

     ```
     /orchestrate-dynamic-workflow
     $workflow_name = project-setup
     ```

     to:

     ```
     /gh-issue-tracking-init
     ```

     (no args — defaults resolve to the clone + `plan_docs/`).
   - Rename the caller's parameter from `$TriggerProjectSetup` to something that
     matches the new target (e.g. `$TriggerHierarchyInit`).
   - Update `create-repo-with-plan-docs.ps1` to use the new parameter name and
     call the updated trigger script.
   - The bootstrap-labels path (`Ensure-DispatchBootstrapLabel` using
     `orchestration:dispatch` label) can stay — it's the dispatch mechanism, not
     the target.
5. **Update the deferred strategy doc** — replace the *Current state* section and
   add a *Cloning pipeline capabilities* section (full text below).
6. **Write a dry-run/throwaway-clone test plan** — once script changes land,
   verify step-by-step against a throwaway clone that memory is blank,
   `docs/plans/.completed/` and `.deferred/` are empty (dirs preserved),
   `run-issues-review/` is gone, AGENTS.md first paragraph correctly says
   "project instance" not "upstream GitHub template", **and** that the dispatch
   issue created by the trigger targets `/gh-issue-tracking-init` (not
   `/orchestrate-dynamic-workflow`).
7. **Document back-flow discipline (W2)** — optionally extract into a rules file
   (e.g. `.agents/rules/source-control.md` addendum) so the discipline is
   referenced where it's applied. Not blocking for W1.

### Risk / open question

- **What about a future clone invocation that passes `-TriggerHierarchyInit $False`** (or whatever the renamed parameter becomes)? The cleanup still runs (it's in the script, not the trigger), so the clone is in a clean state — just without the issue hierarchy built yet. That's correct behavior.
- **What about clones created via "Use this template" directly in GitHub UI,
  bypassing the script entirely?** Those would still carry Class-2 content.
  Mitigation: document in AGENTS.md that instances seeded via the UI must run
  a manual reset step, and point to the creation script as the canonical
  seeding path. (Open question: add this note?)
- **`trigger-project-setup.ps1` — delete or rename?** After step 4 of the task
  list, the existing `trigger-project-setup.ps1` is dead code (it only knew how
  to dispatch the old orchestrator). Two choices: (a) rewrite its body in-place
  with the new `/gh-issue-tracking-init` dispatch, or (b) delete it and create a
  new `trigger-gh-issue-tracking-init.ps1` with a clean name. Recommend **(b)**
  — the old name is misleading and the old parameter `$TriggerProjectSetup` is
  stale; starting fresh avoids ambiguity.

---

## Implementation (deferred to implementation agent)

The implementation agent will apply the changes above. Exact diffs and file
locations for each task will be produced when the agent executes. For the
strategy-doc update, the agent should:

1. Replace the **Current state (verified 2026-07-18)** section with the revised
   **Current state (verified 2026-07-19)** version below.
2. Add a new **Cloning pipeline capabilities (verified 2026-07-19)** section
   immediately before *Current state*, containing the content below.
3. In the *Work items* section, rewrite **W1** to reflect the split between
   "already handled" (steps 4–5) and "to be added to the creation script" (steps
   1–3 + AGENTS.md rewrite fix).
4. Mark **W3** as resolved with the "well-known paths" recommendation.
5. Update **Out of scope / open questions** to:
   - Drop "which workflow owns it" (answered: the creation script).
   - Add the "manual UI-clone reset" documentation decision.
   - Keep the defect-level and architectural-branch questions unchanged.

### Proposed new section: Cloning pipeline capabilities

````markdown
## Cloning pipeline capabilities (verified 2026-07-19)

Repo creation is driven by the external launcher repo
[`nam20485/workflow-launch2`](https://github.com/nam20485/workflow-launch2),
entry-point
[`scripts/create-repo-from-slug.ps1`](https://github.com/nam20485/workflow-launch2/blob/main/scripts/create-repo-from-slug.ps1),
which delegates to
[`scripts/create-repo-with-plan-docs.ps1`](https://github.com/nam20485/workflow-launch2/blob/main/scripts/create-repo-with-plan-docs.ps1).
Typical invocation:

```pwsh
./scripts/create-repo-from-slug.ps1 `
  -Slug "gap-miner-v2" -TemplateRepoName "agent-context" `
  -TriggerProjectSetup $False -Yes
```

**What the script currently does post-clone:**

| Step | Description |
| --- | --- |
| Create repo | `gh repo create --template intel-agency/agent-context` |
| Poll readiness | `Wait-TemplateReady` polls commits endpoint until the template initial commit lands |
| Provision secrets/vars | `GEMINI_API_KEY` (from env), `VERSION_PREFIX='0.0.1'` |
| Clone locally | `git clone` to `../dynamic_workflows/<full-repo-name>` |
| **Seed plan docs** | `Copy-PlanDocs` copies `plan_docs/<slug>/*` into the clone's `plan_docs/` (**W1 step 4**) |
| **Name placeholder replace** | `Update-TemplatePlaceholders` replaces every occurrence of the template repo name and owner in file contents *and* filenames; asserts zero remaining matches |
| **AGENTS.md semantic rewrite** | Targets `**GitHub template repo**` and replaces with `**project instance** cloned from ... template` (**see bug noted under W1 — anchor literal currently mismatches**) |
| Commit + push | Single seed commit; handles template-race rebase by re-running all of the above after `pull --rebase` |
| **Trigger follow-up workflow (W1.5) — BROKEN** | When `-TriggerProjectSetup $True` (default), the script calls `trigger-project-setup.ps1` which creates an `orchestration:dispatch` issue invoking `/orchestrate-dynamic-workflow $workflow_name = project-setup`. **Problem:** this orchestrator was ported from a different template and is largely incompatible with `agent-context`'s new structure. The user's example invocation explicitly passes `-TriggerProjectSetup $False` to bypass it. Needs to be replaced with a dispatch that invokes `/gh-issue-tracking-init` directly (no args — its defaults resolve to the current repo + seeded `plan_docs/`). |

**Verified against a real cloned instance**
([`intel-agency/gap-miner-v2-delta12`](https://github.com/intel-agency/gap-miner-v2-delta12),
created 2026-07-19): plan-doc seeding and placeholder replacement are working,
but Class-2 material described in W1 steps 1–3 survives verbatim.
````

### Proposed replacement text: Current state (verified 2026-07-19)

````markdown
## Current state (verified 2026-07-19)

- **W1 step 4 (seed plan docs) is handled** by `Copy-PlanDocs` in the creation
  script.
- **W1 step 5 (build hierarchy) trigger is broken.** `-TriggerProjectSetup $True`
  dispatches `/orchestrate-dynamic-workflow $workflow_name = project-setup` — a
  project-setup orchestrator ported from a prior template that is largely
  incompatible with `agent-context`'s new structure. The user already bypasses
  this with `-TriggerProjectSetup $False`. Needs to be replaced with a dispatch
  that invokes `/gh-issue-tracking-init` directly (no args — its defaults
  resolve to the current repo + seeded `plan_docs/`, exactly the post-clone
  state). The `$TriggerProjectSetup` parameter name is also stale and should be
  renamed.
- **W1 steps 1–3 are NOT handled** — verified in
  `intel-agency/gap-miner-v2-delta12`:
  - `.agents/memory.md` carries the full template `Current Activity` (including
    the "Template-repo content strategy" project, the gh-issue-tracking-init
    no-arg-defaults project, the Gap Mining hierarchy recovery project, the
    rules-and-memory consolidation project) plus the template's `Completed Work
    Items`, `Decisions`, and `Remember To Do`. All Class 2; all wrong in a clone.
  - `docs/plans/.completed/*.md` and `docs/plans/.deferred/*.md` (including this
    file) transfer verbatim.
  - Existing foreign artifacts (e.g. the `run-issues-review/` Gap Mining review)
    survive in the clone.
- **AGENTS.md rewrite bug (NEW, 2026-07-19).** The script targets
  `$oldLabel = '**GitHub template repo**'` but the actual template AGENTS.md
  reads `**upstream GitHub template**`. The literal mismatch causes the match
  to silently skip ("already updated"), so the cloned instance's AGENTS.md still
  claims "*this repository … is the upstream GitHub template*" — semantically
  wrong for a downstream instance. Generic name replacement did land
  (`intel-agency/agent-context` → the clone name), but the role label was not
  flipped. Proposed fix: change anchor strategy to (a) template-authoritative —
  reword the template AGENTS.md first paragraph so a stable anchor literal is
  present — or (b) script-authoritative — update `$oldLabel` to match current
  AGENTS.md. **Recommend (a)** for durability.
- `.agents/rules/practices.md:15` already orients the agent to glob `plan_docs/`,
  `docs/plans/`, and `docs/` — so the seeding convention (`plan_docs/` first) is
  consistent with the existing orientation.
- `gh-issue-tracking-init` no-arg defaults are Class 1 (context-neutral).
````

### Recommended rewrite for W1

````markdown
### W1 — Post-clone reset step (additions to the creation script)

The creation script (`create-repo-with-plan-docs.ps1`) already handles W1 step
4 (seed plan docs via `Copy-PlanDocs`). Step 5 (build hierarchy) currently
dispatches an incompatible orchestrator and needs replacement. The remaining
cleanup work — Class-2 removal — also belongs in the same script, ordered BEFORE
`Copy-PlanDocs` and placeholder replacement (so replacement doesn't waste cycles
on files we're about to delete).

Add the following steps to `create-repo-with-plan-docs.ps1`:

1. **W1.1 Reset memory** — delete `.agents/memory.md` and emit a blank skeleton
   inline (section headers only, empty Current Activity). The populated template
   memory is Class 2. Emit inline rather than copying an `assets/` file so the
   creation pipeline remains self-contained.
2. **W1.2 Clear template plans** — delete `docs/plans/.completed/*.md` and
   `docs/plans/.deferred/*.md` (plans *about the template*). Preserve the
   lifecycle directories themselves for the new app's own plans.
3. **W1.3 Remove foreign artifacts** — delete the entire
   `docs/plans/.completed/run-issues-review/` subtree (the Gap Mining review and
   similar downstream-specific reports that should never have lived in the
   template).

**Fix the AGENTS.md rewrite bug:**

4. **W1.4 Fix AGENTS.md anchor** — either (a) reword the template AGENTS.md
   first paragraph so a stable anchor like `**GitHub template repo**` is present
   (preferred — durable), or (b) update `$oldLabel` in the script to match the
   current AGENTS.md literal `**upstream GitHub template**` (cheaper, fragile).
   The rewrite must land so cloned-instance AGENTS.md no longer claims to be the
   upstream template.

**Replace the broken post-creation trigger (W1.5):**

5. **W1.5 Replace hierarchy-init trigger** — `-TriggerProjectSetup $True`
   currently dispatches `/orchestrate-dynamic-workflow $workflow_name = project-setup`
   via `trigger-project-setup.ps1`. That orchestrator was ported from a prior
   template and is incompatible with `agent-context`'s new structure (the user
   already bypasses it with `-TriggerProjectSetup $False`). Replace the trigger
   body so the dispatch issue invokes `/gh-issue-tracking-init` directly (no
   args — its no-arg defaults resolve to the current repo + seeded `plan_docs/`).
   Rename the caller's parameter from `$TriggerProjectSetup` to something that
   matches the new target (e.g. `$TriggerHierarchyInit`). Delete the stale
   `trigger-project-setup.ps1` and create a fresh
   `trigger-gh-issue-tracking-init.ps1` with a clean name.

Open: decide the anchor strategy (a vs. b) for W1.4 before implementing.
````

### Recommended resolution for W3

````markdown
### W3 — Marker / locating convention (RESOLVED)

Resolved in favor of **well-known paths** (originally option a): the script
hard-codes the cleanup targets (`.agents/memory.md`, `docs/plans/.completed/*.md`,
`docs/plans/.deferred/*.md`, `docs/plans/.completed/run-issues-review/`). No
per-file markers, frontmatter, or metadata are needed — these paths are
conventionally fixed in every template and clone. The blank-memory-inline option
(originally one of the W1 open questions) is preferred over shipping an
`assets/` skeleton, keeping the creation pipeline self-contained.

A context-neutral note in the template AGENTS.md describing this reset behavior
(originally option b) remains useful as documentation for humans and agents
operating outside the creation pipeline (e.g. someone who clones via "Use this
template" directly in the GitHub UI), but the script is the enforcement point.
````

### Recommended update: Out of scope / open questions

Replace the existing list with:

````markdown
## Out of scope / open questions

- **AGENTS.md rewrite anchor strategy** (decide before W1.4):
  (a) reword the template AGENTS.md first paragraph to include a stable anchor
  the script can target, or (b) update the script's `$oldLabel` literal to match
  current AGENTS.md wording. Recommend (a) for durability.
- **Defect level** for `gh-issue-tracking-init` is tracked separately in
  [`docs/plans/.deferred/defect-level-plan.md`](.deferred/defect-level-plan.md) —
  unrelated to this strategy.
- Whether the template's *own* development planning should live in a separate
  branch/repo entirely (so it never enters the cloneable tree) is still open;
  the pipeline-based cleanup (W1) is sufficient for now but does not eliminate
  the bootstrap risk that a future `git push` to the template's default branch
  reintroduces Class-2 before the next clone run.
- **Manual UI-clone reset**: should we ship a short AGENTS.md note (or a
  standalone "reset-from-template" script) documenting how to clean up an
  instance created via "Use this template" directly in the GitHub UI — i.e.
  bypassing the creation script entirely? Not strictly required by W1 but the
  gap is real.
- **Hierarchy-init trigger parameter name**: the existing `-TriggerProjectSetup`
  parameter is stale (the "project-setup" orchestrator it dispatches is dead
  code). The new trigger targets `/gh-issue-tracking-init` directly. Candidate
  names: `-TriggerHierarchyInit`, `-TriggerTrackingInit`, `-TriggerGhInit`.
  Pick before implementing W1.5.
````

---

## Validation

- Run `npx --no-install markdownlint-cli2` on the updated strategy doc.
- Once W1.1–W1.5 land in the creation script, verify against a throwaway clone
  that:
  - `memory.md` is a blank skeleton (only section headers; no Current Activity
    items).
  - `docs/plans/.completed/` and `docs/plans/.deferred/` dirs exist but are
    empty.
  - `run-issues-review/` is gone.
  - Cloned AGENTS.md first paragraph correctly says "project instance" (not
    "upstream GitHub template") and names the new repo.
  - With the new trigger on, a dispatch issue is created with body
    `/gh-issue-tracking-init` (not `/orchestrate-dynamic-workflow`).
  - `gh-issue-tracking-init` with no args resolves to the clone + its seeded
    `plan_docs/` (no regression from adding cleanup earlier in the pipeline).

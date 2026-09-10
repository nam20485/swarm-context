---
name: swarm-plan
description: Interactive planning wizard that runs BEFORE a swarm - interrogates a loose app or feature idea one question at a time into a coherent, user-approved application plan at plan_docs/application_plan.md, derives the swarm goal(s) for approval, initializes the GitHub issue-tracking hierarchy, then starts the swarm. Trigger when the user says "plan a swarm", invokes /swarm plan or /swarm-plan, or asks to plan before swarming a new app or feature.
compatibility: Requires the swarm skill (.agents/skills/swarm/), gh-issue-tracking-init (.agents/skills/gh-issue-tracking-init/), and the safe-commit skill (~/.agents/skills/safe-commit/) plus the .agents/rules/app-stacks/ directory, all in the target repo/session, plus an interactive session (this wizard converses with the user).
---

# Swarm Plan (interactive planning frontend for the swarm)

Adapted from the orchestrator-service `plan-app` wizard as the frontend on the swarm:
interrogate the idea to a formal plan, derive the goal, build the GH tracking infra,
then start the swarm with that goal. The plan document is only written after explicit
user approval, and the swarm only starts on an explicitly approved goal.

## Wizard rules

- **Ask ONE thing at a time.** Each step is a gate: ask, wait for the user's reply, then advance. Never combine steps in one message.
- **Recommend a sensible default** whenever helpful, but never silently assume — state the default and let the user accept or change it.
- **Never invent details.** Unknowns become open questions resolved with the user; no fabricated tech choices, numbers, or constraints.
- **Iterate, don't rush.** No file is written before Step 7's final approval.
- **Be concise.** One turn per step; never dump the whole plan prematurely.

## Steps

### Step 1: Existing plan docs?

Ask whether to start from existing plan docs or attached content.

- **Yes** — treat the supplied content as the agreed idea, scope, and stack; skip to Step 5.
- **No** — advance to Step 2.

### Step 2: Natural-language idea

Ask for a plain-language description of the app/feature (restate a supplied `$seed_idea`
for confirmation). Capture it. Advance.

### Step 3: Clarify to understanding

Probe gaps with **3–5 specific, numbered questions per round**; iterate until the
architecture, phases, and deliverables are clear. Common areas: users & scope,
data storage, authn/authz, scaling & state, external integrations, deployment,
non-functional requirements. Advance when the mental model is complete.

### Step 4: Tech stack

Offer the repo's pre-defined stack profiles first — list the slugs found in
[`.agents/rules/app-stacks/`](../../rules/app-stacks/) (e.g. `dotnet-aspire-aspnet-blazor`,
`dotnet-avalonia-xplatform-desktop`, `python-uv-fastapi-vite`) and ask whether one fits.

- **A profile fits** — read that profile file, adopt it wholesale, and record the slug (the plan's Technology Stack cites it; later implementation steps inherit its pinned tooling).
- **No profile fits** — capture the stack free-form: language(s)+runtime version, frameworks, specific libraries, build/package tooling, infrastructure.

Advance.

### Step 5: Draft plan + approval

Assemble a draft covering every section of the bundled template
[`assets/application_plan_template.md`](./assets/application_plan_template.md),
filled from Steps 2–4 (or Step 1 content). Present it; iterate on feedback until
approved. Do not write anything to disk yet.

### Step 6: Coherence analysis

Run a rigor pass on the approved draft: contradictions, cross-cutting concerns
(logging, observability, error handling, configuration, security, idempotency),
missing phases/data flows/failure modes, open questions, security problems, risks.
Resolve or surface each finding as a question. Iterate until the exit criteria hold:

1. **Zero unresolved open questions.**
2. **Coherence** — no contradictions; every feature maps to a phase/task; every task has Context + Acceptance Criteria + Validation.

### Step 7: Finalize + final approval

Present the finalized plan (with all Step 6 resolutions) and ask for explicit final
approval. Changes requested → return to the relevant step. Proceed only on approval.

## After final approval

1. **Logistics** (one combined ask): **slug** (kebab-case), **name** (display name),
   **repo** (target `owner/repo` — v1 is current-repo-only: if the user names a
   different repo, confirm writing to the current repo instead or stop), and target
   branch (default `dev/<slug>` per this repo's branching convention).
2. **Branch.** Create and switch to the target branch before writing — the plan, the
   tracking issues, and the swarm's implementation all live there:
   `git checkout -b <target branch>` off the current base. The swarm runs on this
   branch; merging to the base happens through the repo's PR flow after the run.
3. **Write the plan** to the canonical path `plan_docs/application_plan.md` — this
   path is a hard contract (`gh-issue-tracking-init` resolves primary plans from
   `plan_docs/**/*.md`; the `application-plan` slug is a primary-plan slug), so it is
   NOT user-overridable. Fill every template section; no placeholder text may remain.
4. **Commit the plan** through the repo's `/safe-commit` flow (`git add plan_docs/`
   plus the safe-commit scan), so the committed plan is what the tracking init and
   every swarm task input reference.
5. **Derive swarm goal(s)** and ask for approval:
   - **Primary goal** — one sentence with an observable success criterion, typically
     "Implement Phases 1–N of plan_docs/application_plan.md; done when every plan
     acceptance criterion is checked and the repo's validation gate (validation.ps1)
     exits 0."
   - Optionally, **per-epic goals** the user may prefer to run as separate sequential
     swarms (one swarm per epic, each with its own checkable criterion).
   The goal is what `swarm-state.ps1 init -Goal` records — it must be specific and
   checkable. Proceed only on explicit approval of the goal text. Changes requested →
   revise the derived goal (returning to Step 7 if the plan itself must change),
   amend/re-commit, and re-ask.
6. **Initialize GH tracking** by invoking the `/gh-issue-tracking-init` skill against
   the target repo with the committed plan as the plan source — it builds the
   Plan → Epic → Story → Task sub-issue hierarchy, board, milestones, and labels.
7. **Start the swarm** by continuing into the `swarm` skill flow with the approved
   goal: run its Preflight (permission-mode check), then
   `pwsh .agents/skills/swarm/scripts/swarm-state.ps1 init -Goal "<approved goal>" -MaxSubagents <n>`,
   adopt `.zcode/agents/swarm-orchestrator.md`, and run the loop. Epic stories now
   exist as GH issues, so orchestrator task inputs can cite issue URLs as anchors.

## Output contract

The generated `plan_docs/application_plan.md` includes every template section —
Project Logistics, Overview, Goals, Technology Stack (with stack-profile slug when
adopted), Application Features, System Architecture, Project Structure, Implementation
Plan (phases → workstreams → stories/tasks; each top-level Phase maps to one Epic in
the GH tracking hierarchy, leaf items become Stories, sub-tasks become Tasks),
Mandatory Requirements, Acceptance Criteria, Risk Mitigation, Timeline, Success
Metrics, Repository Branch, Implementation Notes. Every Implementation Plan task
carries **Context**, **Acceptance Criteria**, and **Validation** — the issue
hierarchy and every swarm task input derive from them. No template placeholders or
bracketed text may remain.

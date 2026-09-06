---
name: swarm
description: Run a goal-driven agent swarm on the ZCode harness - initialize a tracked run under .swarm/, adopt the swarm-orchestrator role, and delegate work to least-privilege swarm subagents (generic, implementer, researcher, verifier, reviewer) in a verify-each-round loop until the goal is met or the subagent budget is exhausted. Trigger when the user asks to "start a swarm", "run a swarm", "swarm this goal", or invokes $swarm with a goal and optional max-subagent budget.
compatibility: Requires the ZCode Agent harness (subagent definitions under .zcode/agents/) and PowerShell 7+ (pwsh) on PATH.
---

# Agent Swarm

Run a goal-driven swarm: you adopt the orchestrator protocol from `.zcode/agents/swarm-orchestrator.md`, spawn least-privilege workers as background subagents, and persist every state change through the state script so the loop survives compaction.

## Inputs

- `goal` (required) — the loop invariant. It must be specific and checkable. If the user's goal lacks an observable success criterion, restate it as one before starting and proceed — don't interrogate the user.
- `maxSubagents` (optional, default 50) — total worker spawns for the whole run.

## Preflight

Before anything else: workers run Bash (`pwsh`, `git`, build/test commands). The session must be in **Full access** (Shift+Tab), or the needed command types pre-granted via **Always Allow** (including "Always allow for this project"). Permission requests pause the task and wait indefinitely — the 5-minute auto-continue does not apply to them — and "Edit automatically" still confirms every command, so under "Ask before changes" or "Edit automatically" the swarm stalls on the first worker command.

If the mode is either of those: instruct the user to switch (Shift+Tab) or pre-grant the command types, and abort cleanly until they confirm. Do not initialize a run.

## Start

1. **Resume check:** run `pwsh .agents/skills/swarm/scripts/swarm-state.ps1 status` (a `No swarm runs found` throw means no prior run — proceed to init). If a run has `status` `running` and the user says continue/resume — or a running run exists at skill start — re-read `.zcode/agents/swarm-orchestrator.md`, adopt its body, and continue that run instead of initializing. This is what makes on-disk state survive compaction.
2. Otherwise initialize: `pwsh .agents/skills/swarm/scripts/swarm-state.ps1 init -Goal "<goal>" -MaxSubagents <n>` and capture the printed run id.
3. Read `.zcode/agents/swarm-orchestrator.md` and adopt its body as your operating protocol for the rest of the session. You are the primary session — ZCode subagents cannot spawn subagents, so the orchestrator role must run here, not in a subagent.
4. Optional continuation insurance: tell the user they may run `/goal <objective>` to put the harness's own continuation loop behind the run (`/goal clear` when it finishes). `state.json` stays the source of truth — Goal Mode is insurance, not a dependency.

## Loop

The `while !goal.successful` loop is the orchestrator body's protocol:

- `start-round` (a `BUDGET EXHAUSTED` line stops the run),
- decompose into tasks with disjoint decision ownership,
- budget check per spawn batch (`spawned` vs `maxSubagents` from `status` — the script only enforces this at `start-round`),
- spawn workers in the background (`run_in_background: true`) with `record-task -Status pending` at spawn time; update to `done`/`failed` when completion notifications arrive,
- before `end-round`, no task still `pending`/`running` (poll `TaskOutput -block: false`),
- a **cold** `swarm-verifier` PASS gates `end-round -Verdict met`,
- `end-round -Verdict not-met -Next <next action>` otherwise.

All state mutations go through `swarm-state.ps1`; never hand-edit `.swarm/**/state.json`. Re-entry contract: on any re-invocation (worker completion notification or user message), the first action is `status`; continue a `running` run from where it stands.

## Stop conditions

- `end-round -Verdict met` — the success path. Never followed by `finish` (`end-round met` already set `endedAt`).
- `start-round` printing `BUDGET EXHAUSTED`.
- Stall guard: 3 fruitless rounds.
- Permission-parked or runaway worker: `TaskStop`, recorded `failed`.
- User interrupt.

On stop: if the run is not already finished (`endedAt` null), run `finish -Status stopped -Summary "<why>"`. Then report: rounds, spawns vs budget, the task table from `status`, and the goal evidence — the verifier report that grounded the verdict.

## Operational notes

- Definition changes need a new ZCode session — no hot reload.
- Workers with custom `tools` lists have no MCP or skill tools, and no injected AGENTS.md — their conventions channel is `.agents/rules/swarm-workers.md` plus the task's Constraints element.
- Run state is local-only: `.swarm/` is gitignored.

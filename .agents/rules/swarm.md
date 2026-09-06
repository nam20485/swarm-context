# Swarm

Rules for the goal-driven agent swarm on the ZCode harness — entry point is the `swarm` skill (`$swarm`), operating protocol is `.zcode/agents/swarm-orchestrator.md`.

## Topology

The primary session acts as the orchestrator and spawns worker subagents through the Agent tool — swarm depth is exactly 1. Reason: a ZCode subagent cannot spawn subagents (verified, <https://zcode.z.ai/en/docs/subagents>), so the orchestrator role must run in the primary session; the `swarm-orchestrator` definition's body is adopted by the primary session via the skill (`@`-mentioning it as a subagent gives a solo worker, not an orchestrator).

## Locations

- Agent definitions are real ZCode-format files in `.zcode/agents/` — no symlinks, no canonical copies elsewhere. ZCode-specific definitions are not readable by other harnesses; supporting another harness means generating native definitions for it (deferred until a second harness is chosen).
- The skill lives at `.agents/skills/swarm/` (repo convention; workspace discovery from `.agents/skills/` is empirically confirmed by this repo's existing skills).
- Run state lives under `.swarm/<run-id>/` (`goal.md`, `state.json`, `field-guide.md`) and is gitignored — local-only, never committed.
- Shared worker instructions live in [`.agents/rules/swarm-workers.md`](swarm-workers.md) — the workers' conventions channel (see below).

## Worker types

| Name | Tools | Use for |
|---|---|---|
| `swarm-agent` | Read, Grep, Glob, TodoWrite | default / read-only analysis (template to extend) |
| `swarm-implementer` | Read, Grep, Glob, TodoWrite, Edit, Write, Bash | any file edit or build |
| `swarm-researcher` | Read, Grep, Glob, WebFetch, WebSearch | web / docs research |
| `swarm-verifier` | Read, Grep, Glob, Bash | run verification commands for evidence |
| `swarm-reviewer` | Read, Grep, Glob, Bash | diff / quality review |

Cap: ≤5 dedicated types. All definitions set `injectAgentsMd: false` — workers get their conventions from `.agents/rules/swarm-workers.md` plus the task's Constraints element, not from the primary session's AGENTS.md (whose mandates reference tools they lack).

## Budget

`swarm-state.ps1` enforces `spawned -ge maxSubagents` only at `start-round`. The orchestrator must check `spawned` vs `maxSubagents` (from `status`) before each spawn batch and never exceed the budget within a round. Default budget: 50.

## Stall and permission rules

- Stall guard: 3 consecutive `not-met` rounds with no task status change → `finish -Status stopped`.
- A worker parked on a permission gate is a blocker with stall-guard handling — `TaskStop` + `record-task -Status failed` — never an indefinite wait. Background spawning keeps it from blocking the session, but the round cannot close until it is resolved or stopped.
- Swarm sessions run in **Full access** (Shift+Tab) or with the needed command types pre-granted via Always Allow ("Always allow for this project" included). Never rely on the 5-minute auto-continue — it does not apply to permission requests; they wait indefinitely. "Edit automatically" still confirms every command and is not sufficient.
- Because Full access removes the confirmation layer for the whole session, only run swarms on trusted goals (sandboxed swarm execution was deferred by user decision, 2026-09-05).

## Verdicts

`end-round -Verdict met` is permitted only after a cold `swarm-verifier` task for that round reports `PASS` against the goal's success criterion with verbatim command output — cold means never the worker that did the work, and tasked with only the criterion + verification commands, not the implementer's summary. The orchestrator records verdicts; it never invents one. `end-round met` is the success path and must not be followed by `finish`; `finish -Status stopped` is for stall/interrupt/recording the end of a budget-exhausted run.

## Skill self-containment exception

The swarm skill's orchestrator protocol intentionally lives at the agent-definition discovery path `.zcode/agents/swarm-orchestrator.md`; this is the documented exception to skill self-containment (`.agents/rules/skills.md`) — agent definitions must live at their discovery path, and duplicating the protocol in the skill would drift.

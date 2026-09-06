# Agent Swarm Implementation Plan (ZCode harness)

## Context

Implement `docs/plans/swarm-plan.md`: a goal-driven agent swarm for the ZCode harness — custom subagent definitions, a `swarm` skill that sets the goal and runs the loop (`while !goal.successful`, max subagents default 50), and AGENTS.md-linked instructions. ZCode-format subagent definitions live directly at the ZCode workspace discovery path `.zcode/agents/` as **real files — no symlinks** (user decision, 2026-09-06: the definitions are ZCode-specific, other agents/harnesses cannot read them, so linking into a shared canonical tree buys nothing; supporting another harness means generating native definitions for it — deferred until that harness is chosen). The skill lives at `.agents/skills/swarm/` per repo convention; workspace skill discovery from `.agents/skills/` is empirically confirmed (this repo's two existing skills load from there). Run state persists on disk in gitignored `.swarm/<run-id>/` so the loop survives compaction. The existing scaffold `.zcode/agents/swarm-orchestrator.md` and `.zcode/agents/swarm-agent.md` (2-line bodies, machine-specific model ids) is superseded: both files are replaced in place with expanded definitions, and four more worker types are added alongside.

**Hard harness constraint (verified, <https://zcode.z.ai/en/docs/subagents>): a ZCode subagent cannot spawn subagents.** Swarm depth is exactly 1: the *primary session* acts as the orchestrator (adopting `swarm-orchestrator.md`'s body via the skill) and spawns worker subagents through the Agent tool. The `swarm-orchestrator` definition can still be `@`-mentioned as a subagent, but then it can only work solo — its body states this.

## Approach

Steps 1 and 2 are independent of each other; step 3 depends on both; step 4 depends on steps 2 and 3 equally (worker table + skill entry point); step 5 (`.gitignore`) depends on nothing and can land anytime; step 6 last.

### Step 1 — Run-state script + Pester suite + validation wiring

New file `.agents/skills/swarm/scripts/swarm-state.ps1` (no existing equivalent; deterministic state manager per `.agents/rules/skills.md` scripts-over-prose rule). Cross-platform pwsh 7+, `$ErrorActionPreference = 'Stop'`, `throw` for fatal errors, comma-guard array returns, `PSObject.Properties` null-guards under `Set-StrictMode`, timestamps `[DateTimeOffset]::UtcNow.ToString('o')`. Pin serialization to `$state | ConvertTo-Json -Depth 10` on the state object — never on a bare array property — so `tasks: []` and single-task states survive round-trips (PowerShell unwraps single-element arrays in some pipeline forms).

Interface — first positional parameter `Operation` with `ValidateSet('init','start-round','record-task','end-round','append-note','finish','status')`; every operation takes `-BaseDir` (default `.swarm`, relative to CWD); all but `init` take `-RunId` (default: lexicographically latest `run-*` dir under `-BaseDir`; throw with message `No swarm runs found under '<BaseDir>'` if none).

- `init -Goal <string> -MaxSubagents <int = 50> [-BaseDir]` — run id `run-<yyyyMMdd-HHmmss>` (UTC); throw `Run directory already exists: <path>` on collision (re-run a second later; no retry logic). Creates `<BaseDir>/<runId>/` containing `goal.md` (the goal string verbatim, one line), empty `field-guide.md`, and `state.json` (schema below). Prints the run id to stdout, nothing else.
- `start-round [-RunId] [-BaseDir]` — if `status -ne 'running'`, throw `Run '<runId>' is not running (status: <status>)`. If `spawned -ge maxSubagents`: set `status = 'stopped'`, write, print `BUDGET EXHAUSTED: spawned <spawned> of <maxSubagents> subagents; run stopped.` and exit 0 (the orchestrator must see this, not an exception). Note: this leaves `endedAt` null — the run is stopped but not finished. Otherwise `round += 1`, append `{ "round": <n>, "startedAt": <ts>, "endedAt": null, "verdict": null, "next": null }` to `rounds`, print the round number.
- `record-task -TaskId <string> -Agent <string> -Summary <string> -Status <ValidateSet('pending','running','done','failed')> [-Round <int>] [-BaseDir] [-RunId]` — upsert into `tasks` by `id`. **New task id → `spawned += 1` and `round` defaults to current round; existing id → update fields only, no increment.** Print the task JSON.
- `end-round -Verdict <ValidateSet('met','not-met')> [-Next <string>] [-BaseDir] [-RunId]` — `-Next` is optional (store `$null` when omitted); the protocol requires it only on `not-met` rounds, where it carries the next action. Closes the current round: sets its `verdict`, `next`, `endedAt`; if `met`, also sets top-level `status = 'achieved'`, `endedAt`, `summary = 'Goal met in round <n>'`. Throw if no round is open (`No open round in run '<runId>'`). Print `Round <n> <verdict>. Next: <next>` or, when met, `Goal met in round <n>`.
- `append-note -Text <string> [-BaseDir] [-RunId]` — append `- <Text>` line to `field-guide.md`, collapsing any embedded newlines in `-Text` to spaces (the script enforces single-line bullets). Print nothing.
- `finish -Status <ValidateSet('stopped')> -Summary <string> [-BaseDir] [-RunId]` — set top-level `status`, `endedAt`, `summary`. **The already-finished guard is `endedAt -ne $null`** (throw `Run '<runId>' already finished (status: <status>)`) — status-based reading would break the budget path, which sets `status = 'stopped'` without `endedAt`. `finish` takes only `stopped`: the success path never calls it (below). Print `Run <runId> <status>: <summary>`.
- `status [-BaseDir] [-RunId]` — print `state.json` verbatim.

`state.json` schema (exact field names; `ConvertTo-Json -Depth 10`):

```json
{
  "runId": "run-20260905-223000",
  "goal": "<goal string>",
  "maxSubagents": 50,
  "spawned": 0,
  "round": 0,
  "status": "running",
  "summary": null,
  "startedAt": "<iso8601>",
  "endedAt": null,
  "tasks": [
    { "id": "T1", "agent": "swarm-implementer", "summary": "...", "status": "pending", "round": 1 }
  ],
  "rounds": [
    { "round": 1, "startedAt": "...", "endedAt": null, "verdict": null, "next": null }
  ]
}
```

`status` values: `running | achieved | stopped`. Round `verdict` values: `met | not-met`. `end-round -Verdict met` is the normal success path — it sets `status = 'achieved'`, `endedAt`, and the summary; the orchestrator must **not** call `finish` afterward (it would throw on the `endedAt` guard). `finish -Status stopped` is the explicit stop override with a custom summary for stall guard, user interrupt, or recording the end of a budget-exhausted run.

New file `.agents/skills/swarm/scripts/tests/SwarmState.Tests.ps1` (Pester 5; follows `.agents/skills/update-powershell-standard/scripts/tests/UpdatePowershellStandard.Tests.ps1` conventions). Every `Describe` uses a temp `-BaseDir` (`Join-Path ([IO.Path]::GetTempPath()) "swarm-tests-$(New-Guid)"`) removed in `AfterAll`; never touches repo `.swarm/`. One `BeforeAll` per `Describe` (repo-verified gotcha 1 in `.agents/rules/validation.md`); single-quoted here-strings `@'…'@` for any fixture containing backticks (gotcha 2). Cover, at minimum (each a plausible bug → >85% command coverage per `.agents/rules/ci-cd.md`): init creates dir + 3 files + schema fields + default `maxSubagents` 50; init collision throws; start-round increments and throws when not running; start-round budget-exhausted transition to `stopped` + exact stdout line; `finish` after a budget-exhausted `start-round` **succeeds** (locks the `endedAt` guard); `end-round` with no open round throws; explicit `-RunId` targeting a non-latest run (default-latest logic); `append-note`/`status` with no runs throw; record-task new-id increments `spawned`, update does not; record-task invalid status rejected; end-round met → `status achieved`; end-round met without `-Next` stores `null`; append-note appends bullet line and collapses embedded newlines to one line; finish twice throws; status prints parseable JSON with `tasks` surviving as an array in a single-task state; missing RunId with no runs throws `No swarm runs found`.

Edit `validation.ps1` (lines 143–150, `Step-Test`): append to both arrays —

```powershell
        (Join-Path $repoRoot '.agents/skills/swarm/scripts/tests')
```
to `$testPaths` and
```powershell
        (Join-Path $repoRoot '.agents/skills/swarm/scripts')
```
to `$coveragePaths` (keep existing trailing-comma style).

Verify step 1: `pwsh -c "Invoke-Pester -Path .agents/skills/swarm/scripts/tests -Output Detailed"` all green; `./validation.ps1 -Step test` passes ≥85% coverage including `swarm-state.ps1`.

### Step 2 — Agent definitions (real files in `.zcode/agents/`)

Six files at the ZCode workspace discovery path `.zcode/agents/`, replacing the two scaffold files in place and adding four more. **No symlinks anywhere in this design** (user decision, 2026-09-06): the definitions are ZCode-format and ZCode-specific — cross-harness support means generating native definitions per harness later, not sharing these files — and real files avoid both the unverified symlink-following behavior and Windows/git symlink materialization problems entirely. Workspace-level agent discovery at `.zcode/agents/` is empirically confirmed: the scaffold defs are live agent types in the current session.

ZCode subagent format (frontmatter + system-prompt body, camelCase keys per <https://zcode.z.ai/en/docs/subagents>). **`injectAgentsMd: false` on all six** (user decision, 2026-09-06): depth-1 workers must not receive AGENTS.md mandates for tools they lack (sequentialthinking/Memory MCP, delegation rules for an agent that cannot delegate); their channels to repo conventions are the shared worker-instructions file below and the task's `Constraints` element. The orchestrator too: when adopted by the primary session via the skill, AGENTS.md is already injected natively; as a solo `@`-mentioned subagent its body is self-contained.

Preserve the machine-specific model literals from the existing scaffold (they are the user's working config): orchestrator `model: "custom:91b0a8e2-0f6e-4c15-9047-77d99187a400:qwen3.8-max"`, all workers `model: "custom:builtin%3Azai-coding-plan:GLM-5.3-Flash"`. Omit `thoughtLevel` and `mcpServers` everywhere. A custom `tools` list is exhaustive — every unlisted tool, MCP and skill invocation included, is unavailable; that is intended least-privilege.

**Shared worker instructions — new file `.agents/rules/swarm-workers.md`** (rules tree = conventions home; deliberately not in `.zcode/agents/`, so it can never be mistaken for an agent definition). Content: the report contract (`DONE:`/`BLOCKED:` first line + evidence bullets), scope discipline, recognition of the four-element task input, single-line note discipline, and the key line — *your task's `Constraints` element names the governing rules files; read them — that is your only channel to repo conventions (validation, coding style) now that AGENTS.md is not injected; if a repo convention matters for swarm workers, copy it into this file.* Every worker body's **first line**: `First, read and follow [.agents/rules/swarm-workers.md](../../.agents/rules/swarm-workers.md).` Keep each body self-sufficient for its core contract (report format, scope discipline) so a skipped read degrades gracefully rather than breaking the swarm.

Exact frontmatter per file (body specs follow each):

`.zcode/agents/swarm-orchestrator.md` (supersedes the scaffold's 1-line body):
```yaml
---
name: "swarm-orchestrator"
description: "Orchestrates the swarm: adopts the goal-loop protocol, decomposes the goal, delegates to least-privilege swarm subagents, and records round verdicts grounded in cold-verifier evidence. Intended to be adopted by the primary session via the swarm skill; as a subagent it cannot spawn workers."
color: yellow
model: "custom:91b0a8e2-0f6e-4c15-9047-77d99187a400:qwen3.8-max"
injectAgentsMd: false
---
```
Body sections (write prose to this spec):
1. **Role** — you plan, delegate, and record verdicts; you never implement, and you never invent a verdict (verdicts come from verifier evidence). Depth-1 note: invoked via the `swarm` skill you ARE the primary session and spawn workers through the Agent tool; `@`-mentioned as a subagent you cannot spawn — do the work yourself or report the limitation.
2. **Loop protocol** — per round:
   - `swarm-state.ps1 start-round` (honoring its `BUDGET EXHAUSTED` line by stopping).
   - Decompose remaining work into tasks with disjoint decision ownership (never delegate the same design question to two workers — split-brain prevention).
   - Budget check: the script enforces `spawned -ge maxSubagents` only at `start-round`, so before each spawn batch read `status` and check `spawned` vs `maxSubagents` yourself — never exceed the budget within a round.
   - Spawn each worker through the Agent tool with `run_in_background: true` (background: the primary session stays responsive and results arrive as completion notifications). `record-task -Status pending` **at spawn time**; update to `done`/`failed` when the completion notification arrives — `state.json` then always shows outstanding tasks, which is what makes a missed notification recoverable after compaction. Dependent tasks: spawn only after the prerequisite's completion notification. `TaskOutput` (blocking or `-block: false` poll) collects results; `TaskStop` cancels a runaway worker.
   - Before `end-round`, require no task still `pending`/`running`: poll `TaskOutput -block: false` on anything outstanding. A worker parked on a permission gate is a blocker with stall-guard handling — `TaskStop` + `record-task -Status failed` — never an indefinite wait (background keeps it from blocking the session, but the round cannot close while it waits).
   - **Verdict gate:** `end-round -Verdict met` is permitted **only** after a `swarm-verifier` task spawned for that round reports `PASS` against the goal's success criterion with verbatim command output. The verifier must be **cold**: never the worker that did the work, and tasked with only the goal's success criterion + verification commands — not the implementer's summary (avoids anchoring the judge on the worker's self-assessment). The orchestrator *records* verdicts; it never invents one. No verifier PASS → the verdict is `not-met` with `-Next` = the failure to address. The verifying task is a normal `record-task` entry, so `state.json` shows which task grounded each round's verdict.
   - `end-round -Verdict met` ends the run — do **not** call `finish` afterward (`end-round met` already set `endedAt`).
   - Stall guard: 3 consecutive `not-met` rounds with no task status change → `finish -Status stopped -Summary "<why>"`.
   - **Re-entry contract:** on any re-invocation — a background worker's completion notification or any user message — the first action is `swarm-state.ps1 status`; if a run is `running`, continue the protocol from where `state.json` stands (open round → collect pending tasks and judge; no open round → `start-round`). Ending a turn while background workers run is safe only because pending `record-task` entries plus this contract make continuation event-driven — never end a turn with an open round and unrecorded work.
3. **Worker selection** — table: default/read-only analysis `swarm-agent`; any file edit or build `swarm-implementer`; web/docs research `swarm-researcher`; run verification commands for evidence `swarm-verifier`; diff/quality review `swarm-reviewer` (verifier and reviewer stay separate definitions by user decision — distinct report contracts). Cap: ≤5 dedicated types total; create a new definition only when an existing type genuinely cannot do the task, and keep its tool list minimal.
4. **Delegation contract** — every task input carries the four elements from `.agents/rules/delegation.md` (Goal / Context with exact file paths and commands / **Constraints naming governing rules files — a MUST, not a nicety: with `injectAgentsMd: false` this is the workers' only channel to repo conventions** / Done when verifiable by the worker itself). Workers start cold and cannot converse: no questions back; blockers go in the report.
5. **Shared context** — after each batch, distill durable findings via `swarm-state.ps1 append-note`; inject relevant field-guide excerpts into later task inputs (stigmergy: the environment carries memory between agents).

`.zcode/agents/swarm-agent.md` — generic worker template (plan doc: "simplest base def … can be extended", "template w/ commented out example properties"):
```yaml
---
name: "swarm-agent"
description: "Generic least-privilege swarm worker: read-only analysis, search, and reporting for one delegated task. Extend this definition (copy it, add only the tools the task needs) when a task requires writing, running commands, or web access."
color: yellow
model: "custom:builtin%3Azai-coding-plan:GLM-5.3-Flash"
injectAgentsMd: false
tools: [Read, Grep, Glob, TodoWrite]
maxTurns: 25
# --- extension examples (copy this file, uncomment what the task needs) ---
# tools: [Read, Grep, Glob, TodoWrite, Edit, Write, Bash]   # implementer
# tools: [Read, Grep, Glob, WebFetch, WebSearch]            # researcher
# tools: [Read, Grep, Glob, Bash]                           # verifier/reviewer
# thoughtLevel: high      # only takes effect together with an explicit model
# disallowedTools: [Bash] # deny-list alternative to the allow-list
# mcpServers: [memory]    # fails fast if the server is not connected
---
```
Body: first line = the read-first directive linking `.agents/rules/swarm-workers.md` (above). Then: execute exactly the delegated task, nothing more; read-only — if the task needs writes/commands, finish with `BLOCKED: needs <capability>`; final report format: first line `DONE: <one-sentence outcome>` or `BLOCKED: <reason>`, then evidence bullets (paths read, findings, sources).

`.zcode/agents/swarm-implementer.md`:
```yaml
---
name: "swarm-implementer"
description: "Swarm worker that edits files and runs build/test commands for one delegated implementation task with explicit Done-when criteria. Use for any task that must change the working tree."
color: green
model: "custom:builtin%3Azai-coding-plan:GLM-5.3-Flash"
injectAgentsMd: false
tools: [Read, Grep, Glob, TodoWrite, Edit, Write, Bash]
maxTurns: 50
---
```
Body: read-first directive, then same report contract as swarm-agent plus: stay inside the task's named files/scope; run the Done-when verification commands yourself and paste real output as evidence; never expand scope or "fix" unrelated code; `DONE` only when Done-when criteria are observably met.

`.zcode/agents/swarm-researcher.md`:
```yaml
---
name: "swarm-researcher"
description: "Read-only swarm worker for codebase investigation and web/documentation research. Returns findings with exact paths, symbols, and source URLs. Cannot modify files."
color: blue
model: "custom:builtin%3Azai-coding-plan:GLM-5.3-Flash"
injectAgentsMd: false
tools: [Read, Grep, Glob, WebFetch, WebSearch]
maxTurns: 25
---
```
Body: read-first directive, then report contract; every claim carries its source (file path + line range, or URL); distinguish verified fact from inference.

`.zcode/agents/swarm-verifier.md`:
```yaml
---
name: "swarm-verifier"
description: "Read-only-plus-Bash swarm worker that runs the goal's verification commands and reports pass/fail with exact output. Proves whether a round met its Done-when criteria; never fixes failures."
color: purple
model: "custom:builtin%3Azai-coding-plan:GLM-5.3-Flash"
injectAgentsMd: false
tools: [Read, Grep, Glob, Bash]
maxTurns: 25
---
```
Body: read-first directive, then: run exactly the commands given; report each as `PASS`/`FAIL` with verbatim output tail; never edit files, never rerun with changed inputs; a FAIL is a valid result — report it, don't hide it. The orchestrator's round verdicts are gated on this worker's PASS.

`.zcode/agents/swarm-reviewer.md`:
```yaml
---
name: "swarm-reviewer"
description: "Read-only swarm worker that reviews a diff or file set for correctness, security, and quality, reporting severity-ranked findings. Never fixes what it finds."
color: orange
model: "custom:builtin%3Azai-coding-plan:GLM-5.3-Flash"
injectAgentsMd: false
tools: [Read, Grep, Glob, Bash]
maxTurns: 25
---
```
Body: read-first directive, then findings as `SEVERITY (critical|major|minor): file:line — issue — suggested fix`; Bash is for reading-only commands (`git diff`, `git log`); no modifications.

(`color` accepts preset names per docs; the exact preset list is undocumented — cosmetic only if a name is unrecognized.)

Verify step 2: each file's frontmatter parses as YAML and contains `name` + `description` (a file missing either is silently ignored by ZCode with a diagnostic); all six contain `injectAgentsMd: false`; each of the five worker bodies' first line references `.agents/rules/swarm-workers.md`.

### Step 3 — `swarm` skill

New file `.agents/skills/swarm/SKILL.md`, Agent Skills spec compliant (`name` matches directory, description <1024 chars). Frontmatter:

```yaml
---
name: swarm
description: Run a goal-driven agent swarm on the ZCode harness - initialize a tracked run under .swarm/, adopt the swarm-orchestrator role, and delegate work to least-privilege swarm subagents (generic, implementer, researcher, verifier, reviewer) in a verify-each-round loop until the goal is met or the subagent budget is exhausted. Trigger when the user asks to "start a swarm", "run a swarm", "swarm this goal", or invokes $swarm with a goal and optional max-subagent budget.
compatibility: Requires the ZCode Agent harness (subagent definitions under .zcode/agents/) and PowerShell 7+ (pwsh) on PATH.
---
```

Body sections:
1. **Inputs** — `goal` (required; the loop invariant — must be specific and checkable: if the user's goal lacks an observable success criterion, restate it as one before starting and proceed, don't interrogate); `maxSubagents` (optional, default 50, total worker spawns for the whole run).
2. **Preflight** (before `init`, so a stall-bound run never creates a run dir) — workers run Bash (`pwsh`, `git`, build/test). The session must be in **Full access** (Shift+Tab) or the needed command types pre-granted via **Always Allow** (including "Always allow for this project"). Permission requests pause the task and wait indefinitely — the 5-minute auto-continue does not apply to them — and "Edit automatically" still confirms every command, so under "Ask before changes" or "Edit automatically" the swarm stalls on the first worker command. If the mode is either of those: instruct the user to switch (Shift+Tab) or pre-grant, and abort cleanly until they confirm — do not initialize.
3. **Start** — (a) resume check: run `swarm-state.ps1 status` (a `No swarm runs found` throw means no prior run); if a run has `status` `running` and the user says continue/resume — or a running run exists at skill start — re-read `.zcode/agents/swarm-orchestrator.md`, adopt its body, and continue that run instead of initializing (this is what makes on-disk state survive compaction). (b) Otherwise run `pwsh .agents/skills/swarm/scripts/swarm-state.ps1 init -Goal "<goal>" -MaxSubagents <n>` and capture the printed run id. (c) Read `.zcode/agents/swarm-orchestrator.md` and adopt its body as your operating protocol for the rest of the session (you are the primary session — ZCode subagents cannot spawn subagents, so the orchestrator role must run here, not in a subagent). (d) Optional continuation insurance: tell the user they may run `/goal <objective>` to put the harness's own continuation loop behind the run (`/goal clear` when it finishes) — `state.json` stays the source of truth; Goal Mode is insurance, not a dependency.
4. **Loop** — the `while !goal.successful` loop is the orchestrator body's protocol: `start-round` → decompose → budget check per spawn batch → background spawns (`run_in_background: true`) with `record-task -Status pending` at spawn → collect completion notifications and update tasks → cold `swarm-verifier` PASS gates `end-round -Verdict met` → `end-round` (with `-Next` on `not-met`). All state mutations go through `swarm-state.ps1`; never hand-edit `.swarm/**/state.json`. Re-entry contract: on any re-invocation, the first action is `status`; continue a `running` run from where it stands.
5. **Stop conditions** — `end-round met` (the success path — never followed by `finish`); `start-round` printing `BUDGET EXHAUSTED`; stall guard (3 fruitless rounds); permission-parked or runaway worker (`TaskStop`, recorded `failed`); user interrupt. On stop: if the run is not already finished (`endedAt` null), `finish -Status stopped -Summary …`, then report: rounds, spawns vs budget, task table from `status`, and the goal evidence — the verifier report that grounded the verdict.
6. **Operational notes** — definition changes need a new ZCode session (no hot reload); workers with custom `tools` lists have no MCP/skill tools and no injected AGENTS.md — their conventions channel is `.agents/rules/swarm-workers.md` plus the task's `Constraints` element; run state is local-only (`.swarm/` is gitignored).

Verify step 3: `uvx --from skills-ref agentskills validate .agents/skills/swarm` → `Valid skill: .agents/skills/swarm` (exact invocation verified working this session; the bare `skills-ref` executable does not exist).

### Step 4 — Rules files + AGENTS.md

New file `.agents/rules/swarm.md`: topology (primary-session orchestrator, depth 1, why); worker-type table (name → tools → when); `.swarm/<run-id>/` layout (`goal.md`, `state.json`, `field-guide.md`) and its gitignored status; budget rules (the script enforces at `start-round` only — the orchestrator checks `spawned` vs `maxSubagents` before each spawn batch and never exceeds it in-round); stall + permission rules (3 fruitless rounds → stop; a permission-parked worker is `TaskStop` + recorded `failed`, never an indefinite wait; swarm sessions run in Full access or with per-type Always-Allow pre-grants; never rely on the 5-minute auto-continue — it does not apply to permission requests; because Full access removes the confirmation layer for the whole session, only run swarms on trusted goals — sandboxing was deferred by user decision); background-worker note (a permission-stalled background worker no longer blocks the *session*, but the round can't close until it is resolved or stopped); verifier-gated verdicts (`end-round -Verdict met` only after a cold `swarm-verifier` PASS with verbatim output; the orchestrator records verdicts, never invents them); pointer to `.agents/rules/swarm-workers.md` (shared worker instructions — the workers' conventions channel now that AGENTS.md is not injected); the skill self-containment exception ("the swarm skill's orchestrator protocol intentionally lives at the agent-definition discovery path `.zcode/agents/swarm-orchestrator.md`; this is the documented exception to skill self-containment"); location rules (definitions are real ZCode-format files in `.zcode/agents/` — no symlinks, no canonical copies elsewhere; the skill lives at `.agents/skills/swarm/`; other harnesses generate their own definitions when support is added — deferred).

Edit `.agents/rules/skills.md`: replace the broken `skills-ref validate ./my-skill` snippet with the verified invocation `uvx --from skills-ref agentskills validate ./my-skill` (package `skills-ref`, executable `agentskills`; the bare `skills-ref` command does not exist); optionally add a pointer to the swarm self-containment exception in `.agents/rules/swarm.md`.

Edit `AGENTS.md` Rules list (after the **App Stacks** entry block, ~line 40): add

```markdown
- **Swarm**: [`.agents/rules/swarm.md`](.agents/rules/swarm.md) — goal-driven agent swarm on the ZCode harness: primary-session orchestrator + ≤5 least-privilege worker types, `$swarm` skill entry point, shared worker rules in `.agents/rules/swarm-workers.md`, run state under gitignored `.swarm/<run-id>/`.
```

(One list entry only — matches the existing brief-with-link pattern; no new top-level AGENTS.md section.)

### Step 5 — `.gitignore`

Append:

```gitignore

# Agent swarm run state (per-run, local only)
.swarm/

# ZCode workspace state — keep only the committed agent definitions
.zcode/*
!.zcode/agents/
```

(The `.zcode/*` + negation pattern re-includes `.zcode/agents/`, whose real definition files are then committed; git re-inclusion works at this level because the exclusion is on the children, not on `.zcode/` itself.)

Verify step 5: `git status --porcelain .zcode .swarm` shows the six definition files and no `.swarm/` noise after a test run; `git check-ignore .swarm/run-x` → ignored; `git check-ignore .zcode/agents/swarm-agent.md` → NOT ignored (exit 1).

### Step 6 — Delivery

Update `.agents/memory.md` Current Activity with a swarm work item per AGENTS.md directive (update as you go — do this incrementally during steps 1–5, and move to Completed at the end). Branch `dev/agent-swarm` from `development`; run `/safe-commit` skill before committing; commit in three groups: (1) state script + tests + `validation.ps1`, (2) agent defs + `swarm-workers.md` + skill + rules + AGENTS.md, (3) `.gitignore`. Run `./validation.ps1` (all steps) before pushing. Run the GUI smoke (§Verification below) — or apply its documented fallbacks — **before opening the PR**, and record the result in the PR body: real-file discovery is already confirmed, so the smoke's job is validating the full protocol end-to-end (background spawns, verifier-gated verdicts, permission preflight). Push, open PR with milestone + project board per `.agents/rules/source-control.md`, monitor CI to green.

## Critical files & anchors

- `.agents/skills/swarm/scripts/swarm-state.ps1` — the loop's only state authority; schema literals above are load-bearing (SKILL.md and orchestrator body reference operation names and the `BUDGET EXHAUSTED` stdout line verbatim).
- `.zcode/agents/swarm-orchestrator.md` — the protocol the primary session adopts; encodes the depth-1 topology, the verifier gate, and the re-entry contract that make the design work.
- `.agents/rules/swarm-workers.md` — the workers' only conventions channel (AGENTS.md not injected); every worker body read-first-links it.
- `validation.ps1:143-150` (`Step-Test` `$testPaths`/`$coveragePaths`) — CI coverage gate wiring; miss this and the new script escapes the >85% rule.
- `.zcode/agents/` — real definition files at the ZCode discovery path (no symlinks by decision; nothing to drift, works on Windows clones).

## Verification

Prereqs: repo root CWD, `pwsh` 7+, `uv`/`uvx`, network for `uvx` first run. Automated checks (implementer runs all):

1. **Skill validity** (step 3): `uvx --from skills-ref agentskills validate .agents/skills/swarm` → stdout contains `Valid skill`.
2. **State script E2E** (step 1): from repo root —
   - `pwsh .agents/skills/swarm/scripts/swarm-state.ps1 init -Goal "prove the swarm loop mechanics" -MaxSubagents 3` → prints `run-<ts>`; `.swarm/run-<ts>/{goal.md,state.json,field-guide.md}` exist; `state.json` parses with `spawned:0, round:0, status:"running", maxSubagents:3`.
   - `start-round` → prints `1`; `record-task -TaskId T1 -Agent swarm-implementer -Summary "x" -Status done` → `spawned` becomes 1; `record-task -TaskId T1 … -Status failed` (same id) → `spawned` stays 1; two more new tasks → `start-round` again prints `BUDGET EXHAUSTED: spawned 3 of 3 subagents; run stopped.` and `state.json` status is `stopped`.
   - `append-note -Text "finding"` → `field-guide.md` last line `- finding`; `finish -Status stopped -Summary "budget test"` → prints `Run run-<ts> stopped: budget test` (succeeds — the budget path left `endedAt` null); `status` prints parseable JSON. In a fresh run: `end-round -Verdict met` without `-Next` succeeds and stores `"next": null`. Delete the `.swarm/run-<ts>/` dirs afterward.
3. **Pester + coverage gate** (step 1): `./validation.ps1` → all steps pass, coverage ≥85% including `swarm-state.ps1`, 0 test failures.
4. **Definitions are real files with the agreed contract** (steps 2 + 5): `Get-Item .zcode/agents/*.md | Select-Object Name,LinkType` → `LinkType` empty on all six (real files, no symlinks); `Get-Content .zcode/agents/swarm-agent.md -TotalCount 3` shows the frontmatter; every file has `name`, `description`, and `injectAgentsMd: false`; each worker body's first line references `.agents/rules/swarm-workers.md`; `git check-ignore` assertions from step 5.

Manual GUI smoke (user performs; ZCode is a desktop app — implementer cannot automate it; report the artifacts above as proof and hand this checklist over):

5. Open the repo as a ZCode workspace → Settings → Skills → Refresh: `swarm` listed, enabled, source = workspace (if missing, apply the skill-discovery contingency below). In chat, `@` list shows the five worker subagents (workspace-level agents don't appear in the Settings UI — that manages user-level only). Start a **new session** (definition changes don't hot-reload), mode = **Full access** (Shift+Tab) — or pre-grant the needed command types via Always Allow — then send: `$swarm goal: create hello-swarm.txt containing exactly SWARM_OK at the repo root, then verify its content; maxSubagents: 3` (ZCode's native trigger is `$`; a `/`-form invocation resolves and is auto-converted on skill selection). Expected observables: the preflight confirms the mode before any run dir appears; the primary agent announces the orchestrator role and a run id; workers spawn in the background — the primary stays responsive during worker runs; ≥1 `swarm-implementer` spawn writes the file; a **required** cold `swarm-verifier` spawn reports PASS with verbatim output, and that report is the basis of the final `met`; `.swarm/run-*/state.json` ends `status:"achieved"` with tasks recorded (pending → done transitions visible), `spawned ≤ 3`, and the verifying task identifiable; `hello-swarm.txt` contains `SWARM_OK`; the final report shows rounds/task table + the verifier evidence. Cleanup: delete `hello-swarm.txt` and the run dir. Optional probes: (a) **permission probe** (~2 min) — in a scratch session under "Edit automatically", delegate one Bash-using task to a worker and confirm a permission prompt actually surfaces (then approve/reject and abandon the run); record the observed behavior in `.agents/rules/swarm.md` next to the mode requirement. (b) **Goal Mode probe** (~5 min) — re-run the hello-swarm goal wrapped in `/goal` with background workers; observe whether goal rounds align with worker completion, whether the verification check accepts the swarm's evidence, whether `TaskStop` on a worker pauses the whole goal, and whether goal state survives session reopen.

## Assumptions & contingencies

- **Workspace skill discovery from `.agents/skills/` is empirical** (this repo's two existing skills load from there), not docs-confirmed. If the smoke's Skills → Refresh doesn't list `swarm`: place a real copy of the skill directory at `.zcode/skills/swarm/` and record the mirror rule in `.agents/rules/swarm.md` (regenerate the copy after any `.agents/skills/swarm/` edit) — copies, never symlinks, per the no-symlink decision.
- **Cross-harness support is deferred** (user decision, 2026-09-06): `.zcode/agents/` holds ZCode-format definitions; supporting another harness means generating native definitions for it, not sharing these files. Worry about it when a second harness is chosen.
- **Model ids are machine-specific** (taken from the user's working scaffold). If a worker fails to launch with a model error on another machine: omit `model` from that definition so it inherits the primary session's model (documented `inherit` behavior).
- **`color` preset names** (`green`/`blue`/`purple`/`orange`) are undocumented; unrecognized values are cosmetic-only failures — leave as-is.
- **Sandboxed swarm execution deferred** by user instruction (2026-09-05); the plan doc's "run in a sandbox!" is out of scope for this change. Full-access operation (see the preflight) makes trusted goals a hard precondition.

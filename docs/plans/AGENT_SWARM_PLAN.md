# Agent Swarm Implementation Plan (ZCode harness)

## Context

Implement `docs/plans/swarm-plan.md`: a goal-driven agent swarm for the ZCode harness — custom subagent definitions, a `swarm` skill that sets the goal and runs the loop (`while !goal.successful`, max subagents default 50), and AGENTS.md-linked instructions. Canonical files live under `.agents/` (repo convention) with symlinks at the paths ZCode discovers (`.zcode/agents/`, `.zcode/skills/swarm`). Run state persists on disk in gitignored `.swarm/<run-id>/` so the loop survives compaction. The existing untracked scaffold `.zcode/agents/swarm-orchestrator.md` and `.zcode/agents/swarm-agent.md` (2-line bodies, machine-specific model ids) is superseded: their content moves to `.agents/agents/` in expanded form and the `.zcode/agents/` files become symlinks.

**Hard harness constraint (verified, <https://zcode.z.ai/en/docs/subagents>): a ZCode subagent cannot spawn subagents.** Swarm depth is exactly 1: the *primary session* acts as the orchestrator (adopting `swarm-orchestrator.md`'s body via the skill) and spawns worker subagents through the Agent tool. The `swarm-orchestrator` definition can still be `@`-mentioned as a subagent, but then it can only work solo — its body states this.

## Approach

Steps 1 and 2 are independent of each other; step 3 depends on both; steps 4–6 depend on 3; step 7 last.

### Step 1 — Run-state script + Pester suite + validation wiring

New file `.agents/skills/swarm/scripts/swarm-state.ps1` (no existing equivalent; deterministic state manager per `.agents/rules/skills.md` scripts-over-prose rule). Cross-platform pwsh 7+, `$ErrorActionPreference = 'Stop'`, `throw` for fatal errors, comma-guard array returns, `PSObject.Properties` null-guards under `Set-StrictMode`, timestamps `[DateTimeOffset]::UtcNow.ToString('o')`.

Interface — first positional parameter `Operation` with `ValidateSet('init','start-round','record-task','end-round','append-note','finish','status')`; every operation takes `-BaseDir` (default `.swarm`, relative to CWD); all but `init` take `-RunId` (default: lexicographically latest `run-*` dir under `-BaseDir`; throw with message `No swarm runs found under '<BaseDir>'` if none).

- `init -Goal <string> -MaxSubagents <int = 50> [-BaseDir]` — run id `run-<yyyyMMdd-HHmmss>` (UTC); throw `Run directory already exists: <path>` on collision (re-run a second later; no retry logic). Creates `<BaseDir>/<runId>/` containing `goal.md` (the goal string verbatim, one line), empty `field-guide.md`, and `state.json` (schema below). Prints the run id to stdout, nothing else.
- `start-round [-RunId] [-BaseDir]` — if `status -ne 'running'`, throw `Run '<runId>' is not running (status: <status>)`. If `spawned -ge maxSubagents`: set `status = 'stopped'`, write, print `BUDGET EXHAUSTED: spawned <spawned> of <maxSubagents> subagents; run stopped.` and exit 0 (the orchestrator must see this, not an exception). Otherwise `round += 1`, append `{ "round": <n>, "startedAt": <ts>, "endedAt": null, "verdict": null, "next": null }` to `rounds`, print the round number.
- `record-task -TaskId <string> -Agent <string> -Summary <string> -Status <ValidateSet('pending','running','done','failed')> [-Round <int>] [-BaseDir] [-RunId]` — upsert into `tasks` by `id`. **New task id → `spawned += 1` and `round` defaults to current round; existing id → update fields only, no increment.** Print the task JSON.
- `end-round -Verdict <ValidateSet('met','not-met')> -Next <string> [-BaseDir] [-RunId]` — closes the current round: sets its `verdict`, `next`, `endedAt`; if `met`, also sets top-level `status = 'achieved'`, `endedAt`, `summary = 'Goal met in round <n>'`. Throw if no round is open (`No open round in run '<runId>'`). Print `Round <n> <verdict>. Next: <next>` or, when met, `Goal met in round <n>`.
- `append-note -Text <string> [-BaseDir] [-RunId]` — append `- <Text>` line to `field-guide.md`. Print nothing.
- `finish -Status <ValidateSet('achieved','stopped')> -Summary <string> [-BaseDir] [-RunId]` — set top-level `status`, `endedAt`, `summary`; throw if already finished (`Run '<runId>' already finished (status: <status>)`). Print `Run <runId> <status>: <summary>`.
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

`status` values: `running | achieved | stopped`. Round `verdict` values: `met | not-met`. `finish` is the explicit stop/achieve override with a custom summary (stall guard, user interrupt); `end-round -Verdict met` is the normal success path.

New file `.agents/skills/swarm/scripts/tests/SwarmState.Tests.ps1` (Pester 5; follows `.agents/skills/update-powershell-standard/scripts/tests/UpdatePowershellStandard.Tests.ps1` conventions). Every `Describe` uses a temp `-BaseDir` (`Join-Path ([IO.Path]::GetTempPath()) "swarm-tests-$(New-Guid)"`) removed in `AfterAll`; never touches repo `.swarm/`. One `BeforeAll` per `Describe` (repo-verified gotcha 1 in `.agents/rules/validation.md`); single-quoted here-strings `@'…'@` for any fixture containing backticks (gotcha 2). Cover, at minimum (each a plausible bug → >85% command coverage per `.agents/rules/ci-cd.md`): init creates dir + 3 files + schema fields + default `maxSubagents` 50; init collision throws; start-round increments and throws when not running; start-round budget-exhausted transition to `stopped` + exact stdout line; record-task new-id increments `spawned`, update does not; record-task invalid status rejected; end-round met → `status achieved`; append-note appends bullet line; finish twice throws; status prints parseable JSON; missing RunId with no runs throws `No swarm runs found`.

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

### Step 2 — Agent definitions (canonical `.agents/agents/`)

New directory `.agents/agents/`. Six files, ZCode subagent format (frontmatter + system-prompt body, camelCase keys per <https://zcode.z.ai/en/docs/subagents>). Preserve the machine-specific model literals from the existing scaffold (they are the user's working config): orchestrator `model: "custom:91b0a8e2-0f6e-4c15-9047-77d99187a400:qwen3.8-max"`, all workers `model: "custom:builtin%3Azai-coding-plan:GLM-5.3-Flash"`. Omit `thoughtLevel` and `mcpServers` everywhere. `injectAgentsMd: true` everywhere (matches scaffold). A custom `tools` list is exhaustive and drops all MCP tools and the skill tool (verified in docs) — that is intended least-privilege.

Exact frontmatter per file (body specs follow each):

`.agents/agents/swarm-orchestrator.md` (supersedes the scaffold's 1-line body):
```yaml
---
name: "swarm-orchestrator"
description: "Orchestrates the swarm: adopts the goal-loop protocol, decomposes the goal, delegates to least-privilege swarm subagents, and verifies each round against the goal. Intended to be adopted by the primary session via the swarm skill; as a subagent it cannot spawn workers."
color: yellow
model: "custom:91b0a8e2-0f6e-4c15-9047-77d99187a400:qwen3.8-max"
injectAgentsMd: true
---
```
Body sections (write prose to this spec):
1. **Role** — you plan, delegate, and verify; you never implement (keeps orchestrator context free of low-level detail). Depth-1 note: invoked via the `swarm` skill you ARE the primary session and spawn workers through the Agent tool; `@`-mentioned as a subagent you cannot spawn — do the work yourself or report the limitation.
2. **Loop protocol** — per round: `swarm-state.ps1 start-round` (honoring its `BUDGET EXHAUSTED` line by stopping) → decompose remaining work into tasks with disjoint decision ownership (never delegate the same design question to two workers — split-brain prevention) → spawn workers in one parallel foreground batch for independent tasks, serialize dependent ones → after each spawn `record-task` → judge round evidence (changed files, command output — plans/effort alone don't count) → `end-round -Verdict met|not-met -Next <next action>`; `met` ends the run; stall guard: 3 consecutive `not-met` rounds with no task status change → `finish -Status stopped -Summary "<why>"`.
3. **Worker selection** — table: default/read-only analysis `swarm-agent`; any file edit or build `swarm-implementer`; web/docs research `swarm-researcher`; run verification commands for evidence `swarm-verifier`; diff/quality review `swarm-reviewer`. Cap: ≤5 dedicated types total; create a new definition only when an existing type genuinely cannot do the task, and keep its tool list minimal.
4. **Delegation contract** — every task input carries the four elements from `.agents/rules/delegation.md` (Goal / Context with exact file paths and commands / Constraints naming governing rules files / Done when verifiable by the worker itself). Workers start cold and cannot converse: no questions back; blockers go in the report.
5. **Shared context** — after each batch, distill durable findings via `swarm-state.ps1 append-note`; inject relevant field-guide excerpts into later task inputs (stigmergy: the environment carries memory between agents).

`.agents/agents/swarm-agent.md` — generic worker template (plan doc: "simplest base def … can be extended", "template w/ commented out example properties"):
```yaml
---
name: "swarm-agent"
description: "Generic least-privilege swarm worker: read-only analysis, search, and reporting for one delegated task. Extend this definition (copy it, add only the tools the task needs) when a task requires writing, running commands, or web access."
color: yellow
model: "custom:builtin%3Azai-coding-plan:GLM-5.3-Flash"
injectAgentsMd: true
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
Body: execute exactly the delegated task, nothing more; read-only — if the task needs writes/commands, finish with `BLOCKED: needs <capability>`; final report format: first line `DONE: <one-sentence outcome>` or `BLOCKED: <reason>`, then evidence bullets (paths read, findings, sources).

`.agents/agents/swarm-implementer.md`:
```yaml
---
name: "swarm-implementer"
description: "Swarm worker that edits files and runs build/test commands for one delegated implementation task with explicit Done-when criteria. Use for any task that must change the working tree."
color: green
model: "custom:builtin%3Azai-coding-plan:GLM-5.3-Flash"
injectAgentsMd: true
tools: [Read, Grep, Glob, TodoWrite, Edit, Write, Bash]
maxTurns: 50
---
```
Body: same report contract as swarm-agent plus: stay inside the task's named files/scope; run the Done-when verification commands yourself and paste real output as evidence; never expand scope or "fix" unrelated code; `DONE` only when Done-when criteria are observably met.

`.agents/agents/swarm-researcher.md`:
```yaml
---
name: "swarm-researcher"
description: "Read-only swarm worker for codebase investigation and web/documentation research. Returns findings with exact paths, symbols, and source URLs. Cannot modify files."
color: blue
model: "custom:builtin%3Azai-coding-plan:GLM-5.3-Flash"
injectAgentsMd: true
tools: [Read, Grep, Glob, WebFetch, WebSearch]
maxTurns: 25
---
```
Body: report contract; every claim carries its source (file path + line range, or URL); distinguish verified fact from inference.

`.agents/agents/swarm-verifier.md`:
```yaml
---
name: "swarm-verifier"
description: "Read-only-plus-Bash swarm worker that runs the goal's verification commands and reports pass/fail with exact output. Proves whether a round met its Done-when criteria; never fixes failures."
color: purple
model: "custom:builtin%3Azai-coding-plan:GLM-5.3-Flash"
injectAgentsMd: true
tools: [Read, Grep, Glob, Bash]
maxTurns: 25
---
```
Body: run exactly the commands given; report each as `PASS`/`FAIL` with verbatim output tail; never edit files, never rerun with changed inputs; a FAIL is a valid result — report it, don't hide it.

`.agents/agents/swarm-reviewer.md`:
```yaml
---
name: "swarm-reviewer"
description: "Read-only swarm worker that reviews a diff or file set for correctness, security, and quality, reporting severity-ranked findings. Never fixes what it finds."
color: orange
model: "custom:builtin%3Azai-coding-plan:GLM-5.3-Flash"
injectAgentsMd: true
tools: [Read, Grep, Glob, Bash]
maxTurns: 25
---
```
Body: findings as `SEVERITY (critical|major|minor): file:line — issue — suggested fix`; Bash is for reading-only commands (`git diff`, `git log`); no modifications.

(`color` accepts preset names per docs; the exact preset list is undocumented — cosmetic only if a name is unrecognized.)

Verify step 2: each file's frontmatter parses as YAML and contains `name` + `description` (a file missing either is silently ignored by ZCode with a diagnostic).

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
2. **Start** — run `pwsh .agents/skills/swarm/scripts/swarm-state.ps1 init -Goal "<goal>" -MaxSubagents <n>`; capture the printed run id; then read `.agents/agents/swarm-orchestrator.md` and adopt its body as your operating protocol for the rest of the session (you are the primary session — ZCode subagents cannot spawn subagents, so the orchestrator role must run here, not in a subagent).
3. **Loop** — the `while !goal.successful` loop is the orchestrator body's protocol: `start-round` → decompose → delegate (four-element task inputs) → `record-task` per spawn → evidence check → `end-round -Verdict …`. All state mutations go through `swarm-state.ps1`; never hand-edit `.swarm/**/state.json`.
4. **Stop conditions** — `end-round met`; `start-round` printing `BUDGET EXHAUSTED`; stall guard (3 fruitless rounds); user interrupt. On stop: `finish -Status achieved|stopped -Summary …` if not already finished, then report: rounds, spawns vs budget, task table from `status`, and the goal evidence.
5. **Operational notes** — definition changes need a new ZCode session (no hot reload); workers with custom `tools` lists have no MCP/skill tools; run state is local-only (`.swarm/` is gitignored).

Verify step 3: `uvx --from skills-ref agentskills validate .agents/skills/swarm` → `Valid skill: .agents/skills/swarm` (exact invocation verified working this session; the bare `skills-ref` executable does not exist).

### Step 4 — Rules file + AGENTS.md

New file `.agents/rules/swarm.md`: topology (primary-session orchestrator, depth 1, why), worker-type table (name → tools → when), `.swarm/<run-id>/` layout (`goal.md`, `state.json`, `field-guide.md`) and its gitignored status, budget/stall rules, delegation-contract pointer to `.agents/rules/delegation.md`, canonical-location rule (definitions and skill live under `.agents/`; `.zcode/` holds only symlinks — edit `.agents/`, never the links).

Edit `AGENTS.md` Rules list (after the **App Stacks** entry block, ~line 40): add

```markdown
- **Swarm**: [`.agents/rules/swarm.md`](.agents/rules/swarm.md) — goal-driven agent swarm on the ZCode harness: primary-session orchestrator + ≤5 least-privilege worker types, `$swarm` skill entry point, run state under gitignored `.swarm/<run-id>/`.
```

(One list entry only — matches the existing brief-with-link pattern; no new top-level AGENTS.md section.)

### Step 5 — ZCode discovery links

Delete the two real scaffold files `.zcode/agents/swarm-orchestrator.md` and `.zcode/agents/swarm-agent.md` (content superseded by step 2). Create relative symlinks (`ln -s <target> <link>` from the link's directory):

- `.zcode/agents/swarm-orchestrator.md` → `../../.agents/agents/swarm-orchestrator.md`
- `.zcode/agents/swarm-agent.md` → `../../.agents/agents/swarm-agent.md`
- `.zcode/agents/swarm-implementer.md` → `../../.agents/agents/swarm-implementer.md`
- `.zcode/agents/swarm-researcher.md` → `../../.agents/agents/swarm-researcher.md`
- `.zcode/agents/swarm-verifier.md` → `../../.agents/agents/swarm-verifier.md`
- `.zcode/agents/swarm-reviewer.md` → `../../.agents/agents/swarm-reviewer.md`
- `.zcode/skills/swarm` → `../../.agents/skills/swarm` (create `.zcode/skills/` first)

Same pattern as the working `~/.zcode/skills/qwencloud-* -> ../../.agents/skills/*` links on this machine. Workspace skill discovery path `<workspace>/.zcode/skills/<name>/SKILL.md` is documented (FAQ #11); workspace subagent markdown files are documented (FAQ #10); symlink-following for either is not explicitly documented — see contingency.

### Step 6 — `.gitignore`

Append:

```gitignore

# Agent swarm run state (per-run, local only)
.swarm/

# ZCode workspace state — keep only committed agent links and skill links
.zcode/*
!.zcode/agents/
!.zcode/skills/
```

(The `.zcode/*` + negations pattern re-includes the two directories whose contents are then committed; git re-inclusion works at this level because the exclusion is on the children, not on `.zcode/` itself.)

Verify step 6: `git status --porcelain .zcode .swarm` shows the seven symlinks as untracked-to-add and no `.swarm/` noise after a test run; `git check-ignore .swarm/run-x` → ignored; `git check-ignore .zcode/agents/swarm-agent.md` → NOT ignored (exit 1).

### Step 7 — Delivery

Update `.agents/memory.md` Current Activity with a swarm work item per AGENTS.md directive (update as you go — do this incrementally during steps 1–6, and move to Completed at the end). Branch `dev/agent-swarm` from `development`; run `/safe-commit` skill before committing; commit in three groups: (1) state script + tests + `validation.ps1`, (2) agent defs + skill + rules + AGENTS.md, (3) symlinks + `.gitignore`. Run `./validation.ps1` (all steps) before pushing; push, open PR with milestone + project board per `.agents/rules/source-control.md`, monitor CI to green.

## Critical files & anchors

- `.agents/skills/swarm/scripts/swarm-state.ps1` — the loop's only state authority; schema literals above are load-bearing (SKILL.md and orchestrator body reference operation names and the `BUDGET EXHAUSTED` stdout line verbatim).
- `.agents/agents/swarm-orchestrator.md` — the protocol the primary session adopts; encodes the depth-1 topology constraint that makes the whole design work.
- `validation.ps1:143-150` (`Step-Test` `$testPaths`/`$coveragePaths`) — CI coverage gate wiring; miss this and the new script escapes the >85% rule.
- `.zcode/agents/`, `.zcode/skills/swarm` — ZCode discovery surface; must be symlinks, not copies, or the two trees drift.

## Verification

Prereqs: repo root CWD, `pwsh` 7+, `uv`/`uvx`, network for `uvx` first run. Automated checks (implementer runs all):

1. **Skill validity** (step 3): `uvx --from skills-ref agentskills validate .agents/skills/swarm` → stdout contains `Valid skill`.
2. **State script E2E** (step 1): from repo root —
   - `pwsh .agents/skills/swarm/scripts/swarm-state.ps1 init -Goal "prove the swarm loop mechanics" -MaxSubagents 3` → prints `run-<ts>`; `.swarm/run-<ts>/{goal.md,state.json,field-guide.md}` exist; `state.json` parses with `spawned:0, round:0, status:"running", maxSubagents:3`.
   - `start-round` → prints `1`; `record-task -TaskId T1 -Agent swarm-implementer -Summary "x" -Status done` → `spawned` becomes 1; `record-task -TaskId T1 … -Status failed` (same id) → `spawned` stays 1; two more new tasks → `start-round` again prints `BUDGET EXHAUSTED: spawned 3 of 3 subagents; run stopped.` and `state.json` status is `stopped`.
   - `append-note -Text "finding"` → `field-guide.md` last line `- finding`; `finish -Status stopped -Summary "budget test"` → prints `Run run-<ts> stopped: budget test`; `status` prints parseable JSON. Delete the `.swarm/run-<ts>/` dir afterward.
3. **Pester + coverage gate** (step 1): `./validation.ps1` → all steps pass, coverage ≥85% including `swarm-state.ps1`, 0 test failures.
4. **Symlinks resolve** (steps 5–6): `Get-Item .zcode/agents/*.md | Select-Object Name,LinkType,Target` → all `SymbolicLink` with targets under `.agents/agents/`; `Get-Content .zcode/agents/swarm-agent.md -TotalCount 3` shows the frontmatter; `Test-Path .zcode/skills/swarm/SKILL.md` → True; `git check-ignore` assertions from step 6.
5. **Frontmatter contract** (step 2): every `.agents/agents/swarm-*.md` has `name` and `description` keys (files missing either are silently ignored by ZCode).

Manual GUI smoke (user performs; ZCode is a desktop app — implementer cannot automate it; report the artifacts above as proof and hand this checklist over):

6. Open the repo as a ZCode workspace → Settings → Skills → Refresh: `swarm` listed, enabled, source = workspace. In chat, `@` list shows the five worker subagents. Start a **new session** (definition changes don't hot-reload), mode = Edit automatically, then send: `$swarm goal: create hello-swarm.txt containing exactly SWARM_OK at the repo root, then verify its content; maxSubagents: 3`. Expected observables: primary agent announces the orchestrator role and a run id; ≥1 `swarm-implementer` spawn writes the file; ≥1 `swarm-verifier`/`swarm-agent` spawn confirms content; `.swarm/run-*/state.json` ends `status:"achieved"` with tasks recorded and `spawned ≤ 3`; `hello-swarm.txt` contains `SWARM_OK`; final report shows rounds/task table. Cleanup: delete `hello-swarm.txt` and the run dir.

## Assumptions & contingencies

- **Symlink discovery in ZCode is unverified** (docs confirm workspace paths, not symlink following). If step 6's GUI smoke shows the skill or agents missing from ZCode's lists: replace the seven symlinks with real file copies under `.zcode/` (canonical stays `.agents/`), and add to `.agents/rules/swarm.md` that `.zcode/agents/` + `.zcode/skills/swarm` are mirrors to regenerate after any `.agents/` edit. No other step changes.
- **Model ids are machine-specific** (taken from the user's working scaffold). If a worker fails to launch with a model error on another machine: omit `model` from that definition so it inherits the primary session's model (documented `inherit` behavior).
- **`color` preset names** (`green`/`blue`/`purple`/`orange`) are undocumented; unrecognized values are cosmetic-only failures — leave as-is.
- **Sandboxed swarm execution deferred** by user instruction (2026-09-05); the plan doc's "run in a sandbox!" is out of scope for this change.

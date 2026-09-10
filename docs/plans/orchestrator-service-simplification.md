# Orchestrator-Service Simplification — Analysis & Plan

Status: PROPOSED (analysis + plan complete; ACP research verified 2026-09-10)
Date: 2026-09-10
Requirements source: [`docs/plans/orchestrator-service-integration.md`](./orchestrator-service-integration.md) (owner's direction notes)
Codebase surveyed: `nam20485/orchestrator-service` @ branch `nam20485`, HEAD `2bd6d06` (2026-09-10; working tree there has 38 modified + 2 untracked files — active parallel work, do not assume the map below matches that uncommitted state)

## 1. Executive summary

Replace the bespoke opencode-attached dispatch and the prompt-encoded rigid state machine in
`orchestrator-service` with: a **strongly typed async `PromptInfo` queue** (net-new — it does not
exist today) feeding an **ACP host** that drives agent CLIs (opencode first) through the Agent
Client Protocol instead of an always-on `opencode serve` container. The GitHub side (App webhook,
HMAC verify, label-filtered dispatch) stays as-is. The rigid "match-clause" workflow cycle is
replaced by an open-ended agent orchestration prompt, per the owner's direction: the models can
handle dev workflows end-to-end now. Two entry paths must exist: **new app** (plan →
`gh-issue-tracking-init` → swarm) and **new feature / existing app** (plan → existing tracking
infra → swarm). The interactive planning wizard frontend has already been ported to the swarm
repo as `/swarm plan` (`.agents/skills/swarm-plan/`, 2026-09-10).

## 2. What exists today (evidence)

| Component | Where | How it works |
|---|---|---|
| Webhook listener | `webhook_receiver/app.py` (FastAPI, :226 `github_webhook`) | HMAC `X-Hub-Signature-256` verify (`github.py`, secret `OS_WEBHOOK_SECRET`) → `should_dispatch` gate (`filters.py:97`: only `issues.labeled` by a non-bot sender with a workflow label; namespaces `orchestration:*`, `gh-issue-tracking:*`, exact `implementation:ready/complete`) → prompt build → FastAPI `BackgroundTasks` → `subprocess.Popen` |
| Orchestration "state pattern" | `webhook_receiver/orchestration_prompt.jinja2.md` (431 L) | **Pure prompt text**: EVENT_DATA first-match-wins match clauses (lines 123–408) executed by the LLM; each clause applies the *next label*, whose webhook re-triggers dispatch (plan-approved → create-epic-v2 → epic-ready → implement-epic → epic-implemented → review-epic-prs → epic-reviewed → report/debrief → epic-complete → next epic). No code state machine exists. |
| Workflow step bodies | external repo `nam20485/agent-instructions` | fetched fresh at runtime; in-repo command is a pointer |
| opencode integration | `runner.py:722 dispatch_to_opencode` → `scripts/prompt.ps1` → `opencode run --attach http://…:4099` | **Always-on** `opencode serve` container (compose `orchestratorservice`, :4099) + one-shot `opencode run` per dispatch; defaults model `qwencloud/qwen3.7-max`, agent `orchestrator`, variant `high`; fail-closed permission block (no `--auto`); watchdog kills permission asks after 60 s |
| Eventing | `event_store.py:58 EventStore` | untyped `deque` + per-subscriber `queue.Queue` → dashboard SSE only. **`PromptInfo` does not exist** (grep-verified) — no Redis, no asyncio.Queue; webhook→agent handoff is BackgroundTasks+Popen |
| Second engine | `beads_loop.py BeadsLoop` (thread) | independent Beads pipeline (plan→DAG→per-bead worktrees→PRs) sharing only `_prompt_script_invocation` + workspace layout; documented as additive/coexisting |
| Interactive wizard | `image/.opencode/skills/plan-app/SKILL.md` (+ template) | 7-gate linear wizard → `plan_docs/application_plan.md` (canonical path, feeds `_plan_tracked()` and per-bead worktrees) — **ported to swarm-context as `swarm-plan`** |
| Notifications back to GH | `runner.py:426 _post_issue_comment` etc. via `gh` CLI | PAT `GH_ORCHESTRATION_AGENT_TOKEN` (no App installation-token minting) |
| Deployment | `compose.yaml` (3 services) + Caddy proxy | `orchestratorservice` (opencode serve), `webhook-receiver` (Python), `webhook-proxy` (Caddy, `/webhooks/github` + `/health` only) |

Known gap stated in-repo (`image/.opencode/AGENTS.md:41`): nothing currently drives implementation
after `/gh-issue-tracking-init` builds the hierarchy — exactly the gap the swarm integration closes.

## 3. Target architecture

```
GH App webhook ──► webhook listener (FastAPI, unchanged contract)
                      │ constructs PromptInfo
                      ▼
              PromptInfo async queue (net-new, strongly typed)
                      │ consumer
                      ▼
              ACP host (replaces orchestrator-service dispatch + opencode-serve container)
                ├─ agent-orchestration prompt (open-ended pseudo-code workflow,
                │   replaces the jinja2 match-clause cycle)
                ├─ ACP client registry (opencode first; kilo/qwen/zcode later)
                └─ paths: (a) new app → plan → gh-issue-tracking-init → swarm
                          (b) new feature/existing app → plan → existing tracking → swarm
```

Keep (unchanged): GitHub App + webhook + HMAC; the Python FastAPI listener; the label namespaces
and dispatch gate; Caddy proxy; PAT-based `gh` notifications; the dashboard/SSE store (fed with
new event types). The `orchestratorservice` always-on `opencode serve` container is **deleted** —
the host prompts the CLI over ACP directly.

### 3.1 PromptInfo queue (net-new)

The requirements say "keep", but nothing exists to keep — the only queue-ish thing is the untyped
SSE `EventStore`. Design decisions needed (see open questions): typed dataclass/pydantic model
(id, source, repo, event payload, prompt, priority, enqueue/dedup key, status); backing store
(in-process `asyncio.Queue` vs Redis streams vs sqlite WAL) given the single-listener deployment;
durability/retry semantics for missed dispatches; and whether `EventStore` merges into it or stays
a separate dashboard concern.

### 3.2 ACP host

One process (likely the webhook-receiver itself, or a sibling container) that speaks the Agent
Client Protocol as **host**: launches a configured agent CLI (`opencode` first) as an ACP agent
per prompt (or reuses a warm session), feeds the orchestration prompt + PromptInfo payload,
streams progress to the dashboard, and collects the result. Client selection is config-driven
(“any pre-configured ACP client”): opencode on this host today; kilo code CLI / qwen code / zcode
when they ship ACP agent support.

*(ACP protocol specifics, launch commands, and per-client readiness: see §6 — research pending.)*

### 3.3 Agent orchestration prompt

Replace `orchestration_prompt.jinja2.md`'s rigid clause table with an open-ended prompt carrying
the workflow as pseudo-code / natural language (the owner's direction), e.g.:

```
on PromptInfo p:
  if p is new-app:      plan (swarm-plan wizard or autonomous variant) → gh-issue-tracking-init → swarm
  elif p is feature:    plan against existing tracking → swarm
  else:                 run the named workflow from agent-instructions
  publish & verify (branch, PR, labels) as the in-repo workflows already specify
```

Clauses no longer encode "which label applies next" — the agent decides from the tracking state
(issues/labels queried via `gh`), which also removes the webhook-echo state cycle as the only
progression mechanism. GitHub-side notifications stay (comments, labels, PRs).

## 4. Gap analysis (delta from today)

| Delta | Work |
|---|---|
| `PromptInfo` typed queue | **Net-new.** No code exists. Decide model + backing store + durability; retrofit listener to enqueue instead of BackgroundTasks+Popen. |
| ACP host | **Net-new.** Zero ACP mentions in repo. Replaces `runner.py::dispatch_to_opencode`, `scripts/prompt.ps1`, the `orchestratorservice` container, and the `opencode run --attach` call shape. |
| Watchdog | **Rework or retire.** Today parses opencode stderr glyph logs for permission-asks/idle; over ACP the equivalents are protocol events (permission requests, session update stream). |
| Orchestration prompt | **Rewrite.** 431-line jinja2 match-clause file → open-ended orchestration prompt; workflow bodies stay external in `agent-instructions`. |
| Feature-request path | **Net-new.** Today only the one fixed cycle exists; path (b) needs planning-into-existing-tracking. |
| Swarm invocation | **Net-new bridge.** After planning + tracking init, invoke the swarm (this repo) for implementation; requires the autonomous-client question resolved (§5 Q5). |
| Deletion | `orchestratorservice` compose service + Dockerfile serve CMD; `prompt.ps1` attach path; opencode-stderr parsing in `run_stream.py`/`watchdog.py`/`filters.py` trace blacklist. |

## 5. Open questions (decision log — answer before implementation)

1. **PromptInfo provenance.** The plan says "keep" but the repo has none — was it envisioned in
   `workflow-launch2` or another sibling, or is it greenfield? Greenfield assumed unless corrected.
2. **Queue substrate.** In-process `asyncio.Queue` (matches single-container deployment, no new
   deps, lost on restart) vs Redis (durable, another service) vs sqlite WAL (durable, no new
   service). Recommendation: in-process first with a `PromptInfo` envelope designed for later
   export; add durability only when a missed webhook actually hurts.
3. **ACP opencode status & autonomy — answered by research (§6), pending empirical spike.**
   `opencode acp` is first-class; Python SDK 0.12.1 gives the host side. Permissions: auto-select
   `allow_always` in the host's `request_permission` + opencode `permission` config as
   belt-and-braces; copy acpx's policy shape (`approve-reads` default, per-tool escalation,
   deny-list for destructive tools) to preserve today's fail-closed stance. The Phase-0 spike must
   prove the deny path headless, not just the happy path.
4. **Session shape.** One ACP session per PromptInfo (cold, simple, slower) vs a warm persistent
   session per repo (faster, stateful, risk of context bleed). Recommendation: per-prompt cold
   sessions first; the swarm is the long-running part, not the orchestrator turn.
5. **Who runs the swarm, and on which harness?** The swarm skill is ZCode-specific and
   interactive (permission-gated workers). Options: (a) the ACP host shells out to a
   ZCode/goal-mode run when interactive; (b) opencode itself, as the ACP agent, orchestrates
   swarm-style workers natively (needs opencode-side swarm support — the owner's note); (c) the
   sandbox service from this repo (SwarmSandbox) provisions the environment and the ACP agent
   runs the swarm inside it. The requirements' "then invoke the swarm" implies (a) or (c) for now.
6. **Beads pipeline.** Route BeadsLoop dispatches through the ACP host too (it shares
   `_prompt_script_invocation` — one seams change), or leave it untouched? Recommendation: route
   it through the same host (same seam), keep its loop logic unchanged.
7. **Dashboard/progress.** ACP session/update events → the existing SSE `EventStore` (new event
   types) vs porting `run_stream.py` glyph parsing. Recommendation: protocol events only; delete
   the stderr parser.
8. **Repo & branch logistics.** The work lands in `orchestrator-service` (branch `nam20485`,
   currently dirty with 38 modified files — coordinate/rebase before starting). Swarm-side pieces
   (this repo) are already landed: `swarm-plan` skill, exploration inhibitors in agent defs.
9. **Feature path mechanics.** For path (b): does the feature plan get its own plan doc +
   `gh-issue-tracking-init` re-sync (idempotent), or issues appended under the existing Plan
   issue? `gh-issue-tracking-init` is idempotent and re-syncable — recommendation: re-run it with
   the feature plan as an addendum source.
10. **Model routing.** Today dispatch pins `qwencloud/qwen3.7-max` + variant `high`. Over ACP,
    model choice moves into the host's client config — keep parity or re-pin per workflow?

## 6. ACP research summary (verified 2026-09-10, primary sources)

**Protocol.** ACP v1 is stable (v2 in draft since 2026-07-20 — ignore draft features). JSON-RPC 2.0
over stdio; the **host (client)** launches and drives the **agent (CLI)** subprocess. Host baseline:
answer `session/request_permission`, consume `session/update` notifications (message chunks,
tool_call lifecycle, plan, usage). Agent baseline: `initialize` (version + capability negotiation),
`session/new`, `session/prompt` (returns a stopReason), `session/cancel`. Capability-gated host
extras: `fs/*`, `terminal/*`, `elicitation/create`.

**Client readiness (launcher table).**

| Agent | Launch | Status |
|---|---|---|
| opencode | `opencode acp --cwd <dir>` (stdio nd-JSON; NOT `serve`) | first-class; docs claim full feature parity over ACP; registry v1.18.30 (local 1.18.29); repo now `anomalyco/opencode`; `/undo`+`/redo` unsupported over ACP |
| Kilo Code | `kilo acp` | shipped; registry v7.5.16 |
| Qwen Code | `qwen --acp` | graduated from `--experimental-acp` (2026-01-06); local `--help` confirms; also has `--approval-mode {plan,default,auto-edit,auto,yolo}` (ACP interaction unverified) |
| Gemini CLI | `gemini --acp` | built-in, graduated (`--experimental-acp` deprecated); registry v0.59.0 |
| Claude Code | `claude-agent-acp` adapter | no native ACP (open request anthropics/claude-code#6686); adapter maintained by the protocol org |
| ZCode | community bridge only (`william0wang/zcode-acp`) + open official request (zai-org/feedback#571) | none official — the swarm stays ZCode-native until this changes |

**Python SDK for the host.** `agent-client-protocol` (official, protocol org) — **0.12.1**
(2026-08-16), Python ≥3.10,<3.15; `acp.client`/`acp.agent` async base classes + Pydantic schemas +
`acp.contrib` (session accumulators, **permission brokers**, tool-call trackers); working host
example at `examples/client.py` (`connect_to_agent` → `initialize(PROTOCOL_VERSION)` →
`new_session` → `prompt`). Official but deliberately **pre-1.0** (TS/Rust SDKs are the 1.0 ones) —
pin the exact version and expect 0.x churn. TypeScript SDK is the battle-tested alternative if the
service ever moves off Python.

**Autonomy.** The protocol makes the host the permission authority: `session/request_permission`
carries options `allow_once | allow_always | reject_once | reject_always` — an autonomous host may
auto-select. Belt-and-braces: opencode's `permission` config (allow/ask/deny per tool, works
identically over ACP) can be set so requests never fire. Prior art to copy:
**[`acpx`](https://github.com/openclaw/acpx)** (headless ACP client for orchestrators) — permission
modes `--approve-all` / `--approve-reads` (default) / `--deny-all` plus per-tool JSON policy
(`autoApprove`/`autoDeny`/`escalate`/`defaultAction`).

**Residual unknowns (spike must confirm):** exact opencode floor version for `acp` (docs archived
2025-10-29; releases mention ACP back to v0.15.10); whether TUI `--auto` applies to `acp` mode
(use the config route); the purpose of `acp --port/--hostname/--mdns/--cors` flags (unexplained in
docs — likely a companion endpoint).

## 7. Implementation plan (phased)

- **Phase 0 — Spikes (orchestrator-service, ~1 session each)**
  1. ACP spike: drive `opencode acp --cwd <scratch>` from a Python host script on
     `agent-client-protocol==0.12.1` (pinned) — initialize → new_session → one prompt → collect
     `session/update` → stopReason; then prove the permission deny path headless (request_permission
     auto-reject, and the opencode `permission`-config belt-and-braces). Exit: working spike
     script + §6 residual unknowns resolved (floor version, `--auto` scope, acp network flags).
  2. PromptInfo design doc (model fields, substrate, durability posture) resolving Q1/Q2.
- **Phase 1 — Queue seam (no behavior change)**: define `PromptInfo`; listener enqueues;
  consumer dequeues into the *existing* dispatch path. EventStore gains `prompt_queued`/
  `prompt_consumed` events. Exit: webhook→dispatch flows through the queue; dashboard shows it.
- **Phase 2 — ACP host replaces dispatch**: host launches opencode over ACP per PromptInfo;
  delete `orchestratorservice` container, `prompt.ps1` attach path, stderr glyph parsing;
  watchdog rework onto protocol events (or retire if idle detection is subsumed). Exit: label
  dispatch end-to-end over ACP; compose down to 2 services.
- **Phase 3 — Open-ended orchestration prompt**: replace the jinja2 clause file with the
  pseudo-code workflow prompt; agent decides progression from live tracking state. Exit: the
  existing label cycle driven without clause matching; regression pass over the label matrix.
- **Phase 4 — Paths (a) and (b) + swarm bridge**: new-app path (plan → tracking-init → swarm)
  and feature path (plan → tracking re-sync → swarm) per Q5/Q9 decisions. Exit: both paths
  demonstrated end-to-end on a scratch repo.
- **Phase 5 — Retirement & docs**: remove dead code paths (old runner branches, watchdog
  remnants), update README/AGENTS/GEMINI docs, e2e smoke in the simulator, version bump.

Each phase lands as its own PR to `orchestrator-service`; swarm-context-side work is already
landed (`swarm-plan`, inhibitors) or tracked in this repo.

## 8. Risks

- **ACP maturity drift** (protocol/clients evolving): mitigate with the Phase-0 spike before any
  queue/host code, and keeping the host thin (one client interface).
- **Python SDK is pre-1.0** (0.12.x, breaking changes across minors): pin the exact version,
  vendor the lockfile, and keep the host's SDK surface small (client base class + schema only) so
  bumps are mechanical.
- **Autonomy vs fail-closed permissions**: the single biggest behavioral guarantee to preserve;
  spike must prove the deny path, not just the happy path.
- **Parallel work in the target repo** (dirty tree on branch `nam20485`): land phases small and
  rebase deliberately.
- **Two engines diverging**: if BeadsLoop is left on the old path, its seam (`prompt.ps1`)
  deletion breaks it — Phase 2 must carry both call sites or explicitly stage them.
- **Prompt regression**: the clause table, for all its rigidity, is battle-tested; keep the old
  jinja2 file reachable behind a config flag for one release as a fallback dispatch mode.

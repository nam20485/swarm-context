# Review — `AGENT_SWARM_PLAN.md` (agent swarm implementation plan)

Reviewed 2026-09-05 against first-hand sources: ZCode subagent docs, the live harness session (empirical discovery evidence), `validation.ps1:143-150`, `.agents/rules/{skills,delegation,ci-cd,validation}.md`, `.agents/skills/update-powershell-standard` test conventions, the `.zcode/agents/` scaffold, `.gitignore`, and the source plan `swarm-plan.md`.

**Verdict:** execution-ready. Interfaces, frontmatter, verification steps, and contingencies are unusually precise, and every harness claim I could check held up (see "Verified correct"). The findings below are spec seams and gaps, not design flaws. Apply Bucket A before implementation starts — all are cheap edits to the plan text.

**Update 2026-09-06:** four user-directed changes added as mandatory items in [User-directed updates](#user-directed-updates-2026-09-06) — background worker spawns, `injectAgentsMd: false` with tailored worker instructions, a no-interactive-permission-prompts requirement, and Z.AI MCP server access for the swarm (workspace config files already created — see U4). Fold all four into the plan at approval; update 2 supersedes Bucket A item 6, update 3 supersedes Bucket B item 11. Same day, research into harness Goal Mode produced Bucket A item 18; after the user rejected Goal Mode as a substrate, its two motivating weaknesses were converted into in-plan solutions — item 19 (verifier-gated round verdicts) and the re-entry-contract extension in item 2.

## Scoring method

`Score = Value ÷ Cost`, both 1–10. **Value** = impact on plan success if applied; **Cost** = combined time + complexity + risk of applying the change. Buckets: **A ≥ 4.0** (apply before implementation), **B 2.0–3.9** (apply during), **C < 2.0** (optional / nits).

---

## User-directed updates (2026-09-06) — mandatory, fold into the plan at approval

These are user decisions recorded here so they land in the plan with the rest of the review; scores are included for consistency but the bucket placement follows the directive, not the score.

### U1. Spawn every worker as a `background` agent — **4.0 (Value 8 ÷ Cost 2)**

**Problem.** The orchestrator loop protocol currently says "spawn workers in one parallel foreground batch for independent tasks, serialize dependent ones" ([AGENT_SWARM_PLAN.md:84](./AGENT_SWARM_PLAN.md)). Docs-verified (<https://zcode.z.ai/en/docs/subagents#background>): foreground subagents launched together do run in parallel, but "the main task waits for all of them before continuing" — the primary session blocks for the entire batch's lifetime. One slow or stalled worker (e.g., a Bash call parked on a permission prompt — review item 11) freezes the whole round: the orchestrator can't record state, prepare the next tasks, report progress, or react to a user interrupt while waiting.

**Recommendation.** Change the protocol to: spawn each worker through the Agent tool with `run_in_background: true`. Results arrive automatically ("the result comes back to the main conversation on its own") as completion notifications, and the session's task tools cover the rest: `TaskOutput` (blocking or `block: false` poll) to collect results, `TaskStop` to cancel a runaway worker — a natural complement to the stall guard. Protocol details to add:

- `record-task -Status pending` **at spawn time**, update to `done`/`failed` when the completion notification arrives — `state.json` then always shows outstanding tasks, which is what makes a missed notification recoverable after compaction.
- Before `end-round`, require no task still `pending`/`running`: poll `TaskOutput -block: false` on anything outstanding.
- Dependent tasks: spawn only after the prerequisite's completion notification.
- Note in `.agents/rules/swarm.md`: a permission-stalled background worker no longer blocks the *session*, but the round can't close until it is resolved or stopped.

Plan sections touched: step 2 orchestrator body §2 (loop protocol), step 3 skill body §3 (Loop), step 4 rules-file spec, verification §6 smoke expectations (unchanged observables; optionally note the primary stays responsive during worker runs).

### U2. `injectAgentsMd: false` on all subagent definitions + shared worker-instructions file — **2.7 (Value 8 ÷ Cost 3)**

**Problem.** The plan sets `injectAgentsMd: true` on all six definitions, feeding every worker the shared [AGENTS.md](../../../AGENTS.md) — whose mandates largely don't apply to a depth-1 worker (sequentialthinking/Memory MCP tools it doesn't have, delegation-layer rules for an agent that can't delegate). This is the confusion review item 6 patched with a body sentence; the user directive is to remove the source instead: disable injection for subagents and give them their own instructions file.

**Verified constraints** (<https://zcode.z.ai/en/docs/subagents>): `injectAgentsMd: false` is the documented opt-out. There is **no** include/reference mechanism in subagent definitions — "the body is the system prompt" and unrecognized frontmatter keys are silently ignored — so a markdown link cannot *auto*-load a shared file into a subagent's context. However, every swarm worker type has the `Read` tool, so a **read-first directive with a markdown link** works as the include.

**Recommendation.**

- All six definitions get `injectAgentsMd: false` — the orchestrator too (when adopted by the primary session via the skill, the primary already has AGENTS.md injected natively; as a solo `@`-mentioned subagent its body is self-contained).
- New shared worker-instructions file `.agents/rules/swarm-workers.md` (rules tree = conventions home; deliberately *not* in `.agents/agents/`, so it can never be mistaken for or symlinked as an agent definition). Each worker body's first line: `First, read and follow [.agents/rules/swarm-workers.md](../../rules/swarm-workers.md).` Keep each body self-sufficient for its core contract (report format, scope discipline) so a skipped read degrades gracefully rather than breaking the swarm.
- `swarm-workers.md` content: report contract (`DONE:`/`BLOCKED:` + evidence bullets), scope discipline, recognition of the four-element task input, single-line note discipline, and the key line — *your task's `Constraints` element names the governing rules files; read them — that is your only channel to repo conventions (validation, coding style) now that AGENTS.md is not injected.*
- Strengthen the delegation contract accordingly: step 2 §4's "Constraints naming governing rules files" becomes a MUST (it was previously just good practice backed by injection).
- Step 4's `.agents/rules/swarm.md` links to `swarm-workers.md`; step 2's verify check asserts `injectAgentsMd: false` on all six files.
- The AGENTS.md restructuring fallbacks (sections per audience / combined + per-type links) are **not** needed under this approach — keep them only as a contingency if the GUI smoke shows workers skipping the read-first directive.

Supersedes review item 6 below (the ignore-inapplicable-instructions body sentence) — apply this instead.

### U3. No interactive permission prompts in the swarm — session must run non-interactive — **4.5 (Value 9 ÷ Cost 2)**

**Problem.** Docs-verified (<https://zcode.z.ai/en/docs/safety-confirm>): ZCode has four permission modes (cycled with Shift+Tab) — **"Ask before changes"** (default; confirms every edit and command), **"Edit automatically"** (edits auto-apply, but **commands still require confirmation**), **"Plan"**, and **"Full access"** ("run with fewer confirmations"). Two hard facts make any `ask`-gated tool fatal to the swarm: a permission-gated request *pauses the task and blocks the composer*, and "permission requests and plan approvals **always wait**" — the 5-minute auto-continue that applies to ordinary questions explicitly does not apply to them. So a gated worker waits forever, foreground or background alike.

The plan's own smoke test specifies "mode = Edit automatically" ([AGENT_SWARM_PLAN.md:262](./AGENT_SWARM_PLAN.md)) — under that mode every `swarm-implementer`/`swarm-verifier` Bash call (`pwsh`, `git`, build/test) prompts, and the smoke stalls on the first worker command. (This is review item 11's risk, now docs-confirmed and worse.)

**Verified constraint:** there is **no documented config-file key for permissions** — pre-approval exists only as session-level UI grants ("Always Allow", "Allow for this session", "Always allow for this project"). So this cannot be encoded in the repo or in subagent frontmatter. The subagents docs describe `tools` purely as *availability* — "Controls which tools this subagent can call"; a custom list "is exhaustive — nothing outside it is available"; the Settings label "All permissions by default" is UI wording the docs gloss as "inherits every tool of the primary session" — and no page ever connects a subagent's tools list to the approval flow. **Docs gap:** the interaction between subagent tool calls and the confirmation system is documented nowhere (subagents, safety-confirm, and FAQ pages all silent); "availability, gated by session mode" is the only reading consistent with the documented facts, and this plan treats it as such — with the probe below closing it empirically. Design consequence: the two controls are complementary layers — `tools` is the capability ceiling (least privilege; under Full access a read-only worker still cannot write), the mode is the execution gate. Neither substitutes for the other.

**Recommendation.**

1. **SKILL.md Start preflight** (before `init`, so a stall-bound run never creates a run dir): state that workers run Bash (build/test/git) and the session must be in **Full access**, or the needed command types pre-granted via **Always Allow** (incl. "Always allow for this project"); if the mode is "Ask before changes" or "Edit automatically", instruct the user to switch (Shift+Tab) and **abort cleanly until they confirm** — do not initialize.
2. **Orchestrator body** loop protocol: a worker parked on a permission gate is a blocker — same handling as the stall guard (`TaskStop` + `record-task -Status failed`), never an indefinite wait. (U1 makes this recoverable: a gated *background* worker doesn't block the session, but the round can't close while it waits.)
3. **`.agents/rules/swarm.md`**: swarm sessions run in Full access (or with per-type Always-Allow pre-grants); never rely on the 5-minute auto-continue (does not apply to permission requests); and — because this removes the confirmation layer for the whole session — only run swarms on trusted goals (sandboxing was deferred by user decision, [AGENT_SWARM_PLAN.md:269](./AGENT_SWARM_PLAN.md)).
4. **Smoke checklist fix**: replace "mode = Edit automatically" with "mode = **Full access** (Shift+Tab)". As written, the smoke stalls on the first implementer command.
5. **Optional 2-minute probe** (closes the docs gap above with first-hand evidence): in a scratch session with mode = "Edit automatically", delegate one Bash-using task to a worker and confirm a permission prompt actually surfaces (then approve/reject and abandon the run). Record the observed behavior in `.agents/rules/swarm.md` next to the mode requirement.

Supersedes review item 11 below — apply this instead.

### U4. Z.AI MCP servers for the swarm — project-local config + per-worker grants — **3.5 (Value 7 ÷ Cost 2)**

**Answer first:** at review time, no — every worker's exhaustive `tools` list dropped all MCP tools; `swarm-researcher` had only the built-in WebFetch/WebSearch. Directive: allow the Z.AI trio (`web-reader`, `web-search-prime`, `zread`) for subagents, and carry all servers defined in `.opencode/opencode.jsonc` in the project-local MCP config.

**Done now (runtime config — created this session, outside the plan's file set):**

- `.zcode/config.json` defines all six servers from `.opencode/opencode.jsonc` in ZCode's schema: `sequential-thinking` and `memory-graph` as pinned stdio servers (`command`/`args`/`env`, `@2026.7.4` — matching opencode and the repo's version-pinning rule), `web-reader`/`zread`/`web-search-prime`/`exa` as `type: "http"` with `url`/`headers`, keys taken from the working user-level `~/.zcode/cli/config.json`. Workspace servers auto-connect at session start (docs-verified); user scope overrides workspace for same-name servers, so this machine's behavior is unchanged while clones gain the servers project-locally.
- **Secrets constraint (docs-verified):** ZCode config stores values literally — the MCP docs document **no** `${VAR}`/`{env:VAR}` interpolation — so a keyed workspace config can never be committed. Verified via `git check-ignore`: `.zcode/config.json` is already ignored by the applied `.zcode/*` pattern. Committed template instead: `.zcode/config.example.json` (placeholders `<Z_AI_API_KEY>`/`<EXA_API_KEY>`); fold-time gitignore addition: `!.zcode/config.example.json` (currently ignored too — verified).
- Tool full names are scope-independent (server names identical in user and workspace scopes): `mcp__web-reader__webReader`, `mcp__web-search-prime__web_search_prime`, `mcp__zread__get_repo_structure`, `mcp__zread__read_file`, `mcp__zread__search_doc`.

**Applied directly to the delivered implementation (branch `dev/agent-swarm`, PR #1 still open — same session as the config files; commit together):**

- ✓ `swarm-researcher`: `tools` += the five full MCP tool names (docs: wildcards like `mcp__server__*` are silently ignored — full names only); added `mcpServers: [web-reader, web-search-prime, zread]` for fail-fast when a required server isn't connected at session start. Built-in WebFetch/WebSearch remain as fallback.
- ✓ `swarm-agent` template: extension examples updated — the researcher example line carries the five MCP tool names, and the `mcpServers` example is now the Z.AI trio.
- ✓ `.agents/rules/swarm.md` (researcher row + new "MCP servers" section) and `.agents/rules/swarm-workers.md` (new "Research tools" section) document the grant, the full-names-only rule, the gitignored-config/template split, and the pointer to `.agents/rules/tools.md` per-server docs.
- ✓ `.gitignore`: `!.zcode/config.example.json` so the committed template survives the `.zcode/*` exclusion.
- `swarm-implementer`/`swarm-verifier`/`swarm-reviewer` stay MCP-free — local work only, least privilege. (Interpretation of the directive: the trio is the allowed MCP *surface*, granted where web/docs access is part of the job. Say the word to broaden it.)
- Smoke addition: in a **new** session, Settings → MCP shows the six servers connected (workspace-sourced); at least one researcher task exercises an MCP tool end-to-end.

---

## Bucket A — apply before implementation (score ≥ 4.0)

### 1. Pin the `finish` guard to `endedAt`, not `status` — the spec currently contradicts its own E2E test — **9.0**

**Problem.** `finish` "throw[s] if already finished" ([AGENT_SWARM_PLAN.md:24](./AGENT_SWARM_PLAN.md)) without defining "finished". Read as *status ≠ running*, the E2E sequence at [AGENT_SWARM_PLAN.md:254](./AGENT_SWARM_PLAN.md) breaks: `start-round`'s budget path sets `status = 'stopped'`, and the very next required step — `finish -Status stopped -Summary "budget test"` — would throw. The endedAt-based reading works (budget path doesn't set `endedAt`), but an implementer can't know that. Related muddle: the skill's stop-conditions section ([AGENT_SWARM_PLAN.md:186](./AGENT_SWARM_PLAN.md)) lists `finish -Status achieved` as a normal path after `end-round met`, yet `end-round met` already sets `endedAt` — so that `finish` call always throws.

**Recommendation.** Three one-line edits: (a) specify the guard as `endedAt -ne $null`; (b) state that after `end-round -Verdict met` the orchestrator must *not* call `finish` — `end-round met` is the success path, `finish` is only for stall/interrupt/budget; (c) drop `'achieved'` from `finish`'s `ValidateSet` or mark it user-interrupt-only. Add the corresponding Pester test (see item 7).

### 2. Add a resume path to the skill — the compaction-survival claim has no consumer — **7.0**

**Problem.** The Context section ([AGENT_SWARM_PLAN.md:5](./AGENT_SWARM_PLAN.md)) sells on-disk state as "so the loop survives compaction", but neither the skill body nor the orchestrator protocol tells a session what to do with an existing run. After compaction (or in a fresh session), the natural behavior per the current SKILL.md is `init` — orphaning the running run.

**Recommendation.** Add one body section to SKILL.md: before `init`, check for a run with `status` `running` (default latest via `swarm-state.ps1 status`); if the user says continue/resume — or a running run exists at skill start — re-read `.agents/agents/swarm-orchestrator.md`, adopt, and continue that run instead of initializing. This is the highest-value-per-line addition in the review.

**Extension (2026-09-06 — folds in the continuation weakness from item 18).** Skill-start resume alone doesn't keep a *live* run advancing: the loop is self-driven, and nothing currently forces the primary session to continue after its turn ends (Goal Mode's harness-enforced continuation is unavailable per the user decision recorded in item 18). Add a **re-entry contract** to the orchestrator body and SKILL.md: on *any* re-invocation — a background worker's completion notification (U1) or any user message — the first action is `swarm-state.ps1 status`; if a run is `running`, continue the protocol from where `state.json` stands (open round → collect pending tasks and judge; no open round → `start-round`). Turn discipline: ending a turn while background workers run is safe *only* because pending `record-task` entries (U1) plus this contract make continuation event-driven — never end a turn with an open round and unrecorded work. Continuation becomes recoverable-by-construction instead of dependent on the model remembering to keep going.

### 3. Budget is only enforced at `start-round` — say so, or close the gap — **6.0**

**Problem.** The only budget check is `spawned -ge maxSubagents` inside `start-round` ([AGENT_SWARM_PLAN.md:20](./AGENT_SWARM_PLAN.md)). Nothing stops the orchestrator from spawning 60 workers *within* round 1 under a budget of 50; "honor the BUDGET EXHAUSTED line" ([AGENT_SWARM_PLAN.md:84](./AGENT_SWARM_PLAN.md)) only fires at the next round boundary.

**Recommendation.** Cheapest fix is documentation: in the orchestrator body's loop protocol and `.agents/rules/swarm.md`, state that the budget is enforced per round and the orchestrator must check `spawned` vs `maxSubagents` (from `status`) before each spawn batch and never exceed it. (A script-level alternative — `record-task` refusing new ids past budget — changes semantics mid-round; not worth it for v1.)

### 4. Add the Windows/git symlink caveat to the contingencies — this is the *template* repo — **6.0**

**Problem.** Step 5 commits seven symlinks, but git on Windows without `core.symlinks=true` + Developer Mode checks them out as plain text files containing the target path. ZCode there would read a garbage agent definition and a non-functional skill link. The existing contingency ([AGENT_SWARM_PLAN.md:266](./AGENT_SWARM_PLAN.md)) covers "ZCode doesn't follow symlinks" but not "git doesn't produce symlinks". This repo is cloned by an external pipeline (`workflow-launch2`) onto machines you don't control, and the repo standard is explicitly cross-platform PowerShell.

**Recommendation.** One contingency bullet: on clones where symlinks aren't materialized, run a regen step (or copy per the existing contingency) — and have `.agents/rules/swarm.md` document `.zcode/agents/` + `.zcode/skills/swarm` as mirrors regenerateable from `.agents/`. Optional follow-up (not this plan): a small `sync-zcode-links.ps1`.

>**FEEDBACK:** I dont want symlinks. They dont make sense anyway- other agents can't read zcode-format subagent definitions, so linking them to the global `.agents/` or client-specific dirs is not necessary. Other clients will need to generate subagent definitions for themselves. We will worry about that once we decided to support other harnesses besides `zcode`. We have already committed heavilty to zcode conventions so this shouldnt be an issue.

### 5. Fix the validator command in `.agents/rules/skills.md` while touching rules — **5.0**

**Problem.** The plan correctly uses `uvx --from skills-ref agentskills validate` ([AGENT_SWARM_PLAN.md:189](./AGENT_SWARM_PLAN.md)) — I re-verified this invocation works (package `skills-ref`, executable `agentskills`). But `.agents/rules/skills.md` line 12 still documents `skills-ref validate ./my-skill`, which doesn't exist. The plan's step 4 (rules edits) should not leave a known-wrong command in the rules tree one file away from the new rules file.

**Recommendation.** Add to step 4: update the validate snippet in `.agents/rules/skills.md` to the verified `uvx` invocation.

### 6. One line in each worker body: what to do when AGENTS.md asks for tools you don't have — **5.0**

**Problem.** `injectAgentsMd: true` injects an AGENTS.md that mandates `sequentialthinking` and the Memory knowledge-graph "for all non-trivial tasks", while the custom `tools` lists deliberately drop all MCP tools — and workers also can't spawn subagents that AGENTS.md's delegation section assumes. Workers may burn turns trying to comply or flag spurious BLOCKEDs.

**Recommendation.** One sentence in every worker body (or at least in `swarm-agent`, the template): "Instructions injected from AGENTS.md that reference tools you lack (MCP, subagent spawning) do not apply to you — proceed with available tools and note the gap in your report." Do not set `injectAgentsMd: false` — the repo conventions are worth the noise.

>**FEEDBACK:** This isn't relevant for subagents. We decided to set `injectAgentsMd: false`. Their `subagents.md` instructions files wil necessarily be tailored to their specific capabilities. If the repo conventions are important then copy them into `subagents.md`.

### 7. Close the unit-test gaps: the `finish` seam and the throw paths — **4.0**

**Problem.** The test list at [AGENT_SWARM_PLAN.md:51](./AGENT_SWARM_PLAN.md) is strong but omits exactly the branches item 1 shows to be under-specified: `finish` after a budget-exhausted `start-round` must *succeed* (locks the `endedAt` guard); `end-round` with no open round throws; explicit `-RunId` targeting a non-latest run (the default-latest logic); `append-note`/`status` with no runs throw.

**Recommendation.** Add those four to the minimum-coverage list. They're each a plausible bug — the repo's own bar for inclusion.

### 8. Gate the PR on the GUI smoke, not just CI — **4.0**

**Problem.** Discovery (symlinks in ZCode) is the plan's only unverified harness assumption, and the smoke that tests it is unordered relative to delivery ([AGENT_SWARM_PLAN.md:238](./AGENT_SWARM_PLAN.md) pushes and opens the PR; the smoke is item 6 of Verification). If discovery fails, you've opened a PR whose head commit needs the contingency rework.

**Recommendation.** One sentence in step 7: run the GUI smoke (or apply the copy contingency) *before* opening the PR, and record the result in the PR body.

>**FEEDBACK:** Symlinks are being removed. They will not be used in this project.

### 18. Harness Goal Mode: add `/goal` continuation insurance now, probe composition, decide adoption later — **4.7 (Value 7 ÷ Cost 1.5)**

**Finding.** ZCode has a native objective loop (`/goal`, <https://zcode.z.ai/en/docs/goal>) that overlaps the plan's outer loop almost one-to-one: rounds that auto-continue until the objective is met; next-step chaining ("each round's title comes from the next action the previous round's verification produced" — the plan's `-Next`); system-persisted goal state across session close/reopen; a per-goal usage budget; `/goal pause|resume|clear` plus plain-language equivalents; composes with the execution modes from U3. Most notably, at each round end "ZCode runs a **separate check** to decide whether the objective has been met" — a harness-side verifier, not the agent grading itself — with an evidence standard **verbatim-equivalent to the plan's**: "a plan, a checklist, a lot of elapsed effort, or a reply that merely sounds conclusive does not count on its own… changed files, command output, and test results do" (plan's orchestrator §2: "judge round evidence (changed files, command output — plans/effort alone don't count)").

That bears on two weaknesses in the current design: (a) the orchestrator **self-grades** every round (`end-round -Verdict` is its own judgment — Goal Mode's separate check removes exactly that bias); (b) continuation between rounds depends on the primary session keeping itself going — Goal Mode is harness-enforced continuation ("instead of watching the agent and repeatedly typing 'continue', you set a goal and wait").

**Constraints (docs-verified).** Goal Mode is user-only — the docs describe "no mechanism for an agent, skill, or other automated component to set a goal". It cannot be set while a task is running; it conflicts with plan mode; "stopping a running task also pauses the goal automatically". Nothing is documented about subagents or background tasks inside goal mode, and compaction survival is untested.

**Recommendation (three parts, in order of commitment).**

1. **Now, in this plan (cheap):** in the swarm skill's Start section, after `init`, instruct: tell the user they may run `/goal <objective>` to put the harness's continuation loop behind the run (and `/goal clear` when it finishes). `state.json` stays the source of truth — Goal Mode is continuation insurance, not a dependency. Mirror one line in `.agents/rules/swarm.md`.
2. **Probe (add to the GUI smoke, ~5 min):** re-run the hello-swarm goal wrapped in `/goal` with background workers; observe whether goal rounds align with worker completion, whether the verification check accepts the swarm's evidence, whether `TaskStop` on a worker pauses the whole goal, and whether goal state survives session reopen.
3. **Decide later, as a separate change (post-probe):** if composition is clean, a follow-up can demote `end-round -Verdict` to bookkeeping and let the harness check decide met/not-met, shrinking the self-grading surface (and possibly state.json). Do **not** restructure this plan around Goal Mode now — it would stack a second unverified harness assumption (goal-mode × background-worker composition) on top of the already-unverified symlink discovery.

**Outcome (user decision, 2026-09-06):** Goal Mode rejected as a substrate (user-only invocation; unverified composition). The two weaknesses it would have fixed are now solved in-plan: self-graded verdicts → item 19; self-driven continuation → the re-entry contract added to item 2. Parts 1–2 above remain as optional insurance/probe only.

### 19. Round verdicts are self-graded — gate `end-round -Verdict met` on an independent verifier pass — **5.3 (Value 8 ÷ Cost 1.5)**

**Problem.** With Goal Mode rejected, the plan keeps its original bias: the orchestrator both *runs* the round (decomposes, delegates, collects) and *grades* it — `end-round -Verdict` is its own judgment. A model that believes the work is done will record `met` on conclusive-sounding summaries, which is precisely what the Goal Mode docs (and the plan's own evidence standard) say doesn't count. The plan already defines a `swarm-verifier` worker ("Proves whether a round met its Done-when criteria") but nothing in the protocol *requires* it for the verdict — orchestrator §2 lists evidence-judging as an orchestrator activity, so the verifier stays optional and the loop's core correctness check remains self-graded.

**Recommendation.** Separation of duties, using only existing machinery:

- Orchestrator body §2 + SKILL.md §3 + `.agents/rules/swarm.md`: `end-round -Verdict met` is permitted **only** after a `swarm-verifier` task spawned for that round reports `PASS` against the goal's success criterion with verbatim command output. The orchestrator *records* the verdict; it never invents one. No verifier PASS → the verdict is `not-met` with `-Next` = the failure to address.
- The verifier must be **cold**: never the worker that did the work, and tasked with only the goal's success criterion + verification commands — not the implementer's summary (avoids anchoring the judge on the worker's self-assessment).
- Tie it into state: the verifying task is a normal `record-task` entry, so `state.json` shows which task grounded each round's verdict.
- Smoke expectation hardening: the current smoke's "≥1 `swarm-verifier`/`swarm-agent` spawn confirms content" becomes a **required** `swarm-verifier` spawn whose report is the basis of the final `met` — incidental confirmation is not enough to prove the gate works.

---

## Bucket B — apply during implementation (2.0–3.9)

### 9. Standardize the skill invocation syntax in the smoke — **3.0**

**Problem.** The smoke sends `$swarm goal: …` ([AGENT_SWARM_PLAN.md:262](./AGENT_SWARM_PLAN.md)) and the skill description says "invokes `$swarm`", but this harness's own skill convention is the slash form (`/swarm`) — the same convention AGENTS.md uses for `/safe-commit`. If `$swarm` doesn't resolve, the smoke fails confusingly at step one.

**Recommendation.** Verify the invocation syntax against current ZCode docs before the smoke; use `/swarm` (or plain "run the swarm skill with goal …") in the checklist, and make the skill description trigger wording match.

>**FEEDBACK:** zcode uses `$` natively. But `/` is resolved and automatically changed on selection of the skill.

### 10. Resolve the self-containment rule conflict explicitly — **3.0**

**Problem.** `.agents/rules/skills.md` requires a skill be "reproducible from its directory alone — no external file dependencies outside the skill's own `scripts/`", but SKILL.md's Start section reads `.agents/agents/swarm-orchestrator.md` at runtime. Full self-containment is impossible anyway (agent definitions must live at their discovery path), so this is a rule conflict to record, not a design to rework.

**Recommendation.** One exception sentence in `.agents/rules/swarm.md` ("the swarm skill's orchestrator protocol intentionally lives at the agent-definition discovery path; this is the documented exception to skill self-containment") and optionally a pointer from `skills.md`.

### 11. Smoke checklist: worker Bash will hit permission prompts — **3.0** — *SUPERSEDED by user-directed update U3 (docs-confirmed; apply U3 instead)*

**Problem.** The smoke's expected flow has `swarm-implementer`/`swarm-verifier` running `pwsh`/`git` under Bash. Depending on the desktop app's permission mode, subagent Bash calls can stall the smoke on approval dialogs — the smoke assumes "mode = Edit automatically" is sufficient, which is unverified. *(U3 verification: it is not sufficient — "Edit automatically" still confirms commands.)*

**Recommendation.** Add to the manual checklist: pre-approve/allowlist the commands (or run the session in the most permissive mode you accept), and note that a stalled spawn awaiting permission looks like a hung swarm. While editing that checklist, add one line to `.agents/rules/swarm.md`: swarm workers execute with the session's permissions — only start swarms on trusted goals (sandboxing was deferred by user decision, [AGENT_SWARM_PLAN.md:269](./AGENT_SWARM_PLAN.md)).

### 12. Make `-Next` optional on `end-round -Verdict met` — **2.0**

**Problem.** `-Next` is mandatory even on the success path where "next" is meaningless, adding ceremony to every met-round call and one more thing the orchestrator can get wrong.

**Recommendation.** Make `-Next` optional; when `-Verdict met` and `-Next` is omitted, store `$null`/`"none"`. Trivial in script and tests; slightly simplifies the protocol. (If you keep it mandatory, no harm — just consistent noise.)

---

## Bucket C — optional / nits (< 2.0)

### 13. Consider merging `swarm-verifier` and `swarm-reviewer` — **1.5**

Their tool lists are identical (`Read, Grep, Glob, Bash`); only body prose and color differ. The plan's own cap rule — "create a new definition only when an existing type genuinely cannot do the task" — argues for one type with both report contracts. Counter-argument: distinct bodies give sharper prompts and the cost is already sunk into the plan. Either position is defensible; don't block on it.

>**FEEDBACK:** SEPARATE

### 14. Dependency-graph wording — **1.0**

"Steps 4–6 depend on 3" ([AGENT_SWARM_PLAN.md:11](./AGENT_SWARM_PLAN.md)) is looser than the rest of the plan: step 6 (`.gitignore`) depends on nothing, and step 4 depends on step 2 (worker table) as much as on 3. Correcting it enables a bit more implementer parallelism; purely a scheduling note.

>**FEEDBACK:** DO IT

### 15. "…and the skill tool (verified in docs)" over-cites — **1.0**

The docs say a custom `tools` list "is exhaustive — nothing outside it is available" and never mention a Skill tool. The conclusion (least privilege, no skills/MCP) is right; the citation claims more than the page says. Reword to "exhaustive, so every unlisted tool — MCP and skill invocation included — is unavailable."

>**FEEDBACK:**  FIX IT

### 16. FAQ citations point at a 404 — **1.0**

`https://zcode.z.ai/en/docs/faq` returns 404, so "FAQ #10/#11" ([AGENT_SWARM_PLAN.md:215](./AGENT_SWARM_PLAN.md)) can't be checked as cited. The underlying claims don't need the citation — workspace agent discovery is empirically confirmed by this very session (the two scaffold defs in `.zcode/agents/` are live agent types here), and workspace skill discovery through symlinks is confirmed by the working `~/.zcode/skills/qwencloud-*` links. Anchor the claim to those observations instead.

>**FEEDBACK:**  FIX IT

### 17. Minor nit pack — **0.5**

- `append-note -Text` with embedded newlines breaks the one-bullet-per-line `field-guide.md` format — either sanitize newlines in the script or document "single line".
- `!.zcode/skills/` re-includes the whole directory, so future junk dropped there is committable by default — acceptable, just be aware.
- PowerShell detail worth a test assertion: `ConvertTo-Json` unwraps single-element arrays in some pipeline forms; pin the exact serialization call (`$state | ConvertTo-Json -Depth 10` on the object, never on a bare array property) so `tasks: []` survives round-trips — the "status prints parseable JSON" test covers this only if a single-task/zero-round state is asserted.

>**FEEDBACK:**  FIX IT

---

## Verified correct (no action needed)

| Plan claim | Evidence |
|---|---|
| Subagents cannot spawn subagents (depth 1) | ZCode subagent docs, verbatim |
| Missing `name`/`description` → file ignored with diagnostic | Docs, verbatim |
| Custom `tools` list is exhaustive; drops all MCP tools | Docs (Skill-tool wording nuance → item 15) |
| `injectAgentsMd` defaults on; covers workspace AGENTS.md (v3.7.1+) | Docs |
| `thoughtLevel` only takes effect with an explicit `model`; unknown keys silently ignored | Docs |
| `color` presets undocumented; `maxTurns` valid | Docs |
| Workspace-level agent discovery works | Empirical: the `.zcode/agents/` scaffold defs are live agent types in the current session (though Settings UI manages user-level only — don't expect these in the Settings list) |
| Symlinked skills are discovered | Empirical: `~/.zcode/skills/qwencloud-*` and `bailian-*` symlinks load in the current session |
| `uvx --from skills-ref agentskills validate` works | Re-ran it: package installs, `validate` subcommand present |
| Foreground subagents run in parallel but "the main task waits for all of them"; background lets it proceed, result "comes back to the main conversation on its own" | Docs (`#background`) — basis for U1 |
| No include/reference mechanism in subagent definitions — "the body is the system prompt"; unrecognized keys silently ignored | Docs — basis for U2 |
| Permission modes: "Ask before changes" (default) / "Edit automatically" (commands still confirm) / "Plan" / "Full access"; permission requests pause the task and "always wait" (no auto-continue); no config-file permission key — only session mode + "Always Allow" grants | Docs (safety-confirm) — basis for U3 |
| Workspace MCP config `.zcode/config.json` → `mcp.servers`; stdio = `command`/`args`/`env`, http = `type`/`url`/`headers`; workspace servers auto-connect at session start; user overrides workspace; **no env-var interpolation** (values stored literally) | Docs (mcp-services) + the working user-level config as schema precedent — basis for U4 |
| `validation.ps1:143-150` anchors and edit shape | Read the file; `$testPaths`/`$coveragePaths` append as spec'd |
| Scaffold described accurately (2-line bodies, exact model ids) | Read `.zcode/agents/*.md` |
| Test conventions + referenced rules files exist | `UpdatePowershellStandard.Tests.ps1`, `delegation.md`, `ci-cd.md`, `validation.md` all present |

## Watch during implementation (no plan change)

- **Skill discovery without symlinks (per the item-4/8 feedback).** `.agents/skills/swarm/` is itself a native workspace discovery path (the config guide's scan order covers `.zcode/skills/` *and* `.agents/skills/`), so dropping the `.zcode/skills` link changes nothing — confirm in the smoke that the skill lists exactly once and nothing in user scope shadows it.
- **`end-round met` → `finish` interplay** falls out of item 1; make sure the skill text and the orchestrator body agree on which one ends a run.
- **Goal Mode interactions (item 18 probe):** `TaskStop` on a runaway worker may auto-pause the whole goal ("stopping a running task also pauses the goal automatically"); `/goal replace` is blocked while any task runs; goal-round boundaries may not wait for background workers — the U1 rule (end rounds only with no pending tasks) is what keeps the two loops from racing.

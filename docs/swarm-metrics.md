# Swarm Metrics

Persistent telemetry for swarm runs. Appended by the `swarm-analyst` worker after each wave (and seeded manually for run-20260906-225248 below). One row per subagent session; anomalies get their own section per run with proposed fixes. Token columns come from `metadata.json` `usage`; note that `inputTokens` is dominated by `cacheReadTokens` (cached context re-reads, ~90-97% observed) — judge real generation cost by `outputTokens` and judge focus by tool calls + duration.

## Run run-20260906-225248 (SwarmSandbox service; baseline seed)

| Agent | Task | Status | Wall | Tool calls | Input tok | Output tok | Cache-read tok |
|---|---|---|---|---|---|---|---|
| t1 | Research pre-seed + Docker remote target | completed | 12 min | 55 | 832,193 | 24,606 | 754,752 |
| t2 | Rework scaffold to revised architecture | completed | 9 min | 59 | 1,102,646 | 20,987 | 1,043,328 |
| t3 (M1) | DockerSandboxProvisioner | completed | 31 min | 54 | 2,144,208 | 47,892 | 2,068,992 |
| t4 (M2) | Sandbox image + entrypoint | completed | 7 min | 22 | 358,152 | 18,793 | 318,720 |
| t5 (M3) | API composition + reaper | completed | 28 min | 65 | 1,659,452 | 33,668 | 1,553,600 |
| t6 (M4) | Blazor UI polish | completed | 29 min | 53 | 1,456,113 | 39,531 | 1,332,416 |
| t7 (M5) | Validation, CI, e2e script | completed | 20 min | 63 | 2,496,966 | 36,053 | 2,417,216 |
| t8 | Docs sync + warning cleanup | completed | 8 min | 42 | 1,054,767 | 17,257 | 981,952 |

(Prior stopped run, for reference: zcode-remote-server researcher — 22 min, 128 tool calls, 5.0M input / 31.5K output; docker-design researcher — 7 min, 14 calls; conventions brief — 1 min, 16 calls.)

### Anomalies and fixes (baseline)

1. **Thinking enabled on all worker requests** — model-io JSONL shows every GLM-5.3-Flash worker request carried `"thinking":{"type":"enabled","budget_tokens":32000}` and `"output_config":{"effort":"max"}`. Fix applied 2026-09-06: `thoughtLevel: off` in all five worker definitions (effective next session). Verify post-fix that model-io shows thinking absent/disabled and wall time per tool call drops.
2. **Compilation-unit contention** — M1/M3/M4 (shared solution) ran 28-31 min vs 7-9 min for exclusive-unit workers (M2, t8, t2), with documented 45 s foreign-error retry loops. Fix applied: one-writer-per-build-unit wave design (`.agents/rules/swarm-workers.md` Cost discipline; orchestrator Wave design).
3. **Private `--artifacts-path` forfeits incremental builds** — full restore+rebuild per iteration for the contended trio. Fix: dropped for sole-writer waves (t9 onward); kept only for genuine co-tenancy.
4. **Unscoped research breadth** — prior-run researcher hit 128 tool calls / 5M input tokens. Fix: research task inputs now cap scope (named sources, "report not-found instead of expanding"), consider `maxTurns` tuning per task.
5. **Duplicate API-surface discovery** — M1 reflection-dumped Docker.DotNet.Enhanced signatures. Fix: inject excerpts from notes into task inputs (orchestrator Wave design).

## Run run-20260906-225248 — post-run telemetry analysis, all 15 subagent sessions (2026-09-06)

Sources: `~/.zcode/cli/agents/sess_46c64f4f-e151-4951-bfcd-2d3c50073345/agent_*/metadata.json`, `~/.zcode/cli/db/db.sqlite` (`tool_usage`/`part`/`turn_usage`), live model-io JSONLs under `~/.zcode/cli/rollout/` (pruned on session completion — completed sessions verified via DB `reasoning` parts instead). Analyst session `dbb3ec64` excluded (self). Wall s/call = `totalDurationMs / totalToolUseCount`.

| Agent | Task | Status | Wall | Calls | Wall s/call | Tool mix (top) | Thinking |
|---|---|---|---|---|---|---|---|
| 6f1487ce | Repo conventions brief (prior run) | completed | 1.9 min | 16 | 7.2 | Read 12, Grep 2 | 6 reasoning parts |
| 8fbe6868 | Research zcode remote server (prior run) | completed | 23.0 min | 128 | 10.8 | Grep 86, Glob 17 | 69 reasoning parts |
| a3a75123 | Research docker provisioning design (prior run) | completed | 7.1 min | 14 | 30.3 | WebFetch 8 | 7 reasoning parts |
| c1a937e6 | Scaffold SwarmSandbox solution | stopped | n/a | 65 | — | Write 22, Bash 19 | 29 reasoning parts |
| 60c650c0 | Rework scaffold to revised architecture | completed | 9.5 min | 59 | 9.7 | Write 18, Bash 17 | 12 reasoning parts |
| b03c2792 | Research pre-seed + Docker remote target | completed | 12.1 min | 55 | 13.2 | Grep 23, Glob 17 | 19 reasoning parts |
| 384a848b | M1 DockerSandboxProvisioner | completed | 31.5 min | 54 | 35.0 | Bash 31, Read 12 | 33 reasoning parts |
| b496d2d5 | M2 sandbox image + entrypoint | completed | 7.7 min | 22 | 20.9 | Bash 9, Write 5 | 11 reasoning parts |
| 795f8436 | M3 API composition + reaper | completed | 29.0 min | 65 | 26.7 | Bash 18, Read 17 | 28 reasoning parts |
| a8eb37ca | M4 Blazor UI polish | completed | 29.6 min | 53 | 33.6 | Bash 25, Read 9 | 29 reasoning parts |
| bbf395b5 | M5 validation, CI, e2e script | completed | 20.1 min | 63 | 19.1 | Bash 31, Read 17 | 35 reasoning parts |
| a93150a0 | Docs sync + warning cleanup | completed | 8.0 min | 42 | 11.5 | Bash 16, Read 13 | 20 reasoning parts |
| cb92125f | Coverage push to 85% gate | completed | 41.1 min | 83 | 29.7 | Bash 53, Edit 16 | 46 reasoning parts |
| cb2c3dc2 | Cold verification of goal | completed | n/a (running at extract) | 8 | — | Bash 7, Read 1 | 6 reasoning parts |
| f3a1a211 | Diff review of SwarmSandbox | completed | n/a (running at extract) | 22 | — | Read 12, Bash 10 | 13 reasoning parts |

### Q1 — thinking config and retries

- Every observed model request (live model-io, 12 requests of f3a1a211 + analyst session): `"thinking":{"type":"enabled","budget_tokens":32000}`, `"output_config":{"effort":"max"}`, `attempt:1`. Verbatim: `1  10502  enabled  32000  max` (attempt, durationMs, thinking.type, budget, effort).
- `turn_usage.model_retry_count` = 0 for all 16 sessions; no `attempt>1` lines in any model-io file. Zero transport/model retries run-wide.
- Completed sessions' model-io JSONLs are pruned at completion; thinking confirmed there via DB `part` rows of type `reasoning` (counts in table; e.g. M1 = 33, coverage = 46).
- Thinking-token share: on tool-call turns the visible output is reasoning-only (f3a1a211: reasoningText 693-6,159 chars/request, final text 0 chars); exact reasoning tokens are redacted in logs (`usageReasoningTokens:"[Redacted]"`).

### Q2 — tool-call histograms and waste

- Dominant tools: implementers are Bash-heavy (M1 31/54, M4 25/53, coverage 53/83); researchers are Grep/Glob-heavy (zcode-remote 86 Grep of 128 calls).
- Wasted pattern A — reflection API-dumping: M1 ran 12 pwsh invocations containing 19 `Assembly.LoadFrom` lines probing Docker.DotNet DLLs (~22% of its calls), violating the >5-exploration-calls rule.
- Wasted pattern B — rebuild-every-patch: coverage agent ran 19 near-identical `dotnet build SwarmSandbox.Tests/...` (one per patch) plus 8 filtered `dotnet test` + 1x3-iteration test loop + 2 `validation.ps1` full runs = 35 of 53 bash calls.
- Re-reads of own-written files (Read after Write/Edit, DB join): coverage 5, Rework 4, M3 4, Scaffold 2, Docs 1, others 0 — minor.
- Research zcode-remote (prior run) remains the call-count outlier (128), already flagged in baseline.

### Q3 — contention quantification (shared-solution trio vs exclusive units)

- Error-code mentions in command output/parts: M1 CS0407 x2 CS0117 x3 CS0246 x2 CS0121 x2; M3 CS0407 x3 CS0117 x2 CS0246 x6 CS0121 x3 CS4014 x2; M4 CS0407 x1 CS0117 x1 CS0246 x3 CS0121 x3 CS4014 x4. Exclusive units: M2/M5/Docs/Rework 0 (Docs CS4014 x18 is quoted doc text, not build output).
- Explicit waits: M1 `sleep 120; dotnet test ...`, `sleep 180; dotnet test ...` (>=5 min parked); M3 `sleep 30`/`sleep 45` retry loops; M4 poll loops `for i in 1..6; do sleep 60; dotnet test ...` and `for i in 1..5; do sleep 90; dotnet test ...` (worst case ~13.5 min polling). M2/M5/Docs/Coverage: zero sleeps.
- Wall s/call: trio mean 31.8 (M1 35.0, M4 33.6, M3 26.7) vs exclusive-unit mean 14.0 (M2 20.9, Docs 11.5, Rework 9.7) — 2.3x, and the trio's tool calls are themselves build-heavy.

### Q4 — coverage-push agent (cb92125f): 41.1 min, 83 calls, 5.17M input / 82K output tokens

- Where calls went: ~5 coverage-XML parses + exploration (1-12), 5 self-file re-reads, then a 40-call measure-fix-rebuild loop: ~13 patch iterations (inline `python3 - <<EOF` / `sed -i`) each followed by `dotnet build SwarmSandbox.Tests` (19x) and filtered `dotnet test` (8x + 1 loop of 3) to re-measure coverage; 2 final `validation.ps1 -Step dotnet` runs. Roughly two-thirds of all calls were rebuild/rerun cycles, not exploration; zero time lost to contention (sole writer, no sleeps, no foreign errors).
- Highest-leverage task-input change: pass the starting per-class uncovered-lines report (from M5's coverage run) as task input and state "measure full coverage once at the end; iterate with `--filter` only; target these named classes" — eliminates most of the 19 rebuilds + repeated full-suite coverage measurement.

### Anomalies and fixes (post-run wave, ranked by impact)

1. **Coverage agent spent ~2/3 of 83 calls on rebuild-measure cycles** (19 builds, 12 test runs, 41.1 min, 5.17M input tok). Fix: feed per-class uncovered-lines baseline into the task input + mandate filtered test runs during iteration, one full coverage measurement at the end.
2. **M4/M1/M3 poll-slept against the shared build** (M4 up to ~13.5 min in `sleep 60/90` loops; M1 parked `sleep 120/180`; trio wall s/call 31.8 vs 14.0 exclusive). Fix: orchestrator staggers shared-solution builds (claim board + solution build lock) so workers rebuild their own csproj only and never poll.
3. **M1 reflection-dumped Docker.DotNet assemblies** (12 pwsh / 19 LoadFrom calls, ~22% of session) despite baseline anomaly 5's fix. Fix: hard-cap exploration calls in task inputs ("report missing signatures after 5 calls") instead of relying on notes injection.
4. **Thinking enabled (32K budget, effort=max) on all worker requests** — baseline anomaly 1's `thoughtLevel: off` fix did not take effect for this run (all requests still `thinking.type:"enabled"`); reasoning is the dominant output on tool turns. Fix: verify worker definitions hot-reload or restart CLI before the next wave; re-check model-io after.
5. **Model-io transcripts are pruned at session completion** — completed agents' per-request thinking/tool/usage detail is unrecoverable (this analysis had to fall back to sqlite `part`/`tool_usage`). Fix: archive (copy) each `model-io-sess_subagent_*.jsonl` to the run dir at session end before cleanup.

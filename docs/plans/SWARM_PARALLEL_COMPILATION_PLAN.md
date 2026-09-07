# Plan: Parallel Subagent Work Within a Compilation Unit

Status: PROPOSED (analysis complete, tier 1-2 adopted, tier 3-4 deferred)
Date: 2026-09-06
Evidence base: swarm run `run-20260906-225248` (SwarmSandbox build-out)

## Problem

Multiple subagents editing disjoint folders of one .NET solution contend on a single
compilation unit. Measured cost in this repo's run:

| Worker | Wall time | Tokens | Build unit |
|---|---|---|---|
| M2 (sandbox image/scripts) | 7.7 min | 0.38M | exclusive |
| t8 (docs + csproj warning fixes) | 8.0 min | 1.07M | near-exclusive |
| M1 (Api/Provisioning) | 31.5 min | 2.19M | shared solution |
| M3 (Api/Services) | 29 min | 1.69M | shared solution |
| M4 (Web + Tests/Web) | 30 min | 1.49M | shared solution |

Cost drivers, in order of observed impact:

1. **Foreign-error retry loops** — a sibling's half-written file breaks the shared
   build; workers poll/retry (M3 ran a 45 s retry loop; M1 and M4 both reported
   waiting out foreign CS-errors).
2. **Forfeited incremental builds** — the mitigation used (per-worker
   `--artifacts-path`) forces a full restore + rebuild per iteration.
3. **Duplicate API-surface exploration** — M1 reflection-dumped
   Docker.DotNet.Enhanced's signatures because no excerpt was injected.
4. **Shared-file hot spots** — csproj/sln/Program.cs edits needed by multiple
   workers (the Tests→Web ProjectReference required orchestrator intervention).

Baseline mitigation already codified (`.agents/rules/swarm-workers.md` "Cost
discipline" + `.zcode/agents/swarm-orchestrator.md` "Wave design"): one writer per
compilation unit per wave; serialize same-unit work; inject API excerpts; cap loops.
This eliminates contention by eliminating intra-unit parallelism.

## Candidate mechanisms (user-proposed toolkit)

### A. Message board

A file-based board under the gitignored run dir (e.g. `.swarm/<run-id>/board/`) where
each worker posts: task id, claimed paths, status, one-line findings. Workers check
the board before starting and before claiming ambiguous paths.

- Value: runtime dedup/visibility beyond the orchestrator's decomposition-time
  disjointness; cheap (2-4 tool calls per worker).
- Risk: low. Stale posts, protocol non-compliance; orchestrator remains the
  authoritative scheduler — the board is advisory.
- Verdict: **cheap, adopt regardless of tier.**

### B. Section lock guards (advisory claims)

Mutex over named sections of the compilation unit (folder/file granularity),
implemented as claim files on the board: `claim-<path-slug>.lock` with task id +
timestamp. A worker refuses (reports BLOCKED) rather than waits — subagents cannot
block indefinitely without burning tokens.

- Value: prevents the shared-file hot-spot class (csproj/sln/Program.cs).
- Risk: low-moderate; deadlock impossible if claims are refuse-not-wait; orphan
  claims need TTL/staleness rules.
- Verdict: adopt for **shared files only** when co-tenancy is used.

### C. Build semaphore + batched shared build

Agents wanting to build signal a semaphore; when N waiters accumulate (or a timer
expires), one build runs for the whole waiting set and all consume the result.

- Value: amortizes build cost across co-tenants.
- Risk: **high with cold subagents.** Requires a persistent broker daemon, a
  signaling protocol, result fan-out, and timeout/error semantics — workers cannot
  converse, so every failure mode becomes a token-burning poll loop. A batched build
  is also only valid if no waiter has edited since it started, which re-introduces
  exactly the foreign-error class the semaphore was meant to manage. Worst case it
  serializes builds anyway — strictly worse than worktrees (no isolation) and more
  complex than serialization (broker).
- Verdict: **reject.** If builds must be shared, the simpler form is "one designated
  builder per wave" (the orchestrator or a verifier runs the integration build;
  workers build only their own csproj).

### D. Worktree-per-subagent + merge-back

Each worker gets `git worktree add .swarm/worktrees/<task> -b swarm/<run>/<task>`
from the current base. Full isolation: no foreign errors, private obj/bin with normal
incremental caching (no `--artifacts-path` needed; the NuGet global packages folder
is already shared). On DONE, the orchestrator merges branches back one at a time and
runs the integration build/test after each merge (or once after a conflict-free
batch).

- Value: restores intra-unit parallelism at near-baseline per-worker speed.
- Risks/costs:
  1. **Cross-module type dependencies break at branch time.** A worker coding
     against a type another worker is creating *in its worktree* cannot compile.
     Mitigation: contract-first waves (all shared interfaces/DTOs land on base
     before the fan-out — this run already did that) + merge order by dependency.
  2. **Shared-file merge conflicts** (csproj/sln): mitigate with mechanism B claims,
     or pre-land all shared-file edits on base before the wave (preferred — the
     orchestrator does them, as with the Tests→Web reference).
  3. **Merge/integration overhead lands on the orchestrator**: N merges + builds per
     wave. Bounded and serial, but it is the orchestrator's context that pays.
  4. Disk/checkout cost per worktree (seconds for a repo this size; minutes for
     monorepos).
- Verdict: **the only mechanism that actually buys back intra-unit parallelism**,
  worth it only when the unit is big enough that serialization is the bottleneck.

## Coherent strategy: tiered selection

Pick the tier by compilation-unit size and wave shape; escalate only when
serialization measurably hurts:

- **Tier 1 (default, codified): serialization by build unit.** One writer per
  compilation unit per wave; parallelize across distinct units. Zero new machinery.
  Per-worker cost ≈ baseline (8 min / ~0.4-1.1M observed).
- **Tier 1.5 (always-on): board + claims + excerpt injection.** Message board (A)
  for visibility/dedup, section claims (B) for shared files, API-surface excerpts
  injected from notes. Costs ~4 tool calls per worker; removes hot-spot stalls and
  exploration waste in every tier.
- **Tier 2 (design-level): project decomposition.** Split the solution so modules
  are independently buildable projects (+ their own test projects). Turns "one
  compilation unit" into several small ones — parallelism without worktrees, and
  better architecture anyway. The Api in this run was the contention magnet because
  M1 and M3 both lived in it.
- **Tier 3 (escalation): worktree-per-subagent (D) + contract-first waves +
  pre-landed shared-file edits + serial merge-back with integration build.** Used
  only when a wave genuinely needs ≥3 concurrent writers inside one unit AND the
  unit cannot be decomposed (Tier 2 unavailable).

## Risk/complexity vs value — comparison with the implemented baseline

Quantified from this run: serialization cost ≈ (31.5 − 8) ≈ 23 min wall per deferred
C# worker, ~0 extra tokens (waiting workers cost nothing; the contended workers'
excess was ~0.5-1M tokens each in retry/rebuild churn — serialization *saves* those
tokens). Worktrees would recover the wall time but add: per-wave orchestrator merge
passes (N merges + integration builds, serial), contract-first scaffolding waves
(one extra round ≈ one worker), and failure modes (conflict resolution, orphan
worktrees, branch drift) that only the orchestrator can absorb — i.e., they move
cost from idle wall-clock (cheap, parallel-safe) onto orchestrator context (the
scarcest resource in a swarm run, and the thing compaction threatens).

Value verdict:

- For **this repo's typical waves** (2-4 C# workers, small solution): Tier 1 + 1.5 +
  2 dominate. Serialization costs minutes of wall time; worktrees cost orchestrator
  attention and a scaffolding round. **Not worth it.**
- For **large units** (monorepo module where 5+ workers × 30+ min serialize into
  hours): Tier 3 flips positive — wall-time savings compound and merge conflicts
  stay rare under disjoint folder ownership + pre-landed shared files.
- The **build semaphore (C) is never worth it** with cold, non-conversational
  subagents: it is the most complex mechanism and its failure modes are exactly the
  token-burning loops we are eliminating.

## Adoption

1. Now (no machinery): keep Tier 1 codified rules; add board + claims protocol
   (Tier 1.5) to `.agents/rules/swarm-workers.md` and the orchestrator definition;
   inject API-surface excerpts as standard task-input content.
2. Next solution-shaped work: apply Tier 2 — module-per-project layout decided at
   scaffold time (the scaffold worker's task input gains this requirement).
3. Tier 3: implement only on first demonstrated need (a wave where serialization
   delay > ~1 h); design sketch above is the spec; requires `swarm-state.ps1`
   extensions for worktree/branch bookkeeping.

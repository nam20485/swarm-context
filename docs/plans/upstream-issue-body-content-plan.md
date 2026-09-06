# Plan — Issue body content fidelity (upstream skill fix)

**From:** forensic review of the `/gh-issue-tracking-init` run against `intel-agency/gap-miner-v2-india89` (Project #92, 30 issues, 2026-07-20).
**Audience:** upstream dev team — maintainers of the canonical template repo + the `gh-issue-tracking-init` skill.
**Purpose:** record every content-fidelity defect found in the generated issue bodies, their root cause, measured performance impact of the fix, and the concrete changes to land upstream so every clone inherits correct, dev-ready issues.
**Companion doc:** [`upstream-handoff-identity-and-phase-warning.md`](./upstream-handoff-identity-and-phase-warning.md) covers three *separate* upstream defects (AGENTS.md identity mislabel, `set-project-fields.ps1` Phase-warning bug, the Phase→Epic mapping rule). This doc is about **what the issue bodies contain**.

---

## 1. Headline finding

The generated issue bodies are **not development-ready**: they mix real, plan-derived content with **generic boilerplate filler** that is identical across many issues and carries no task-specific information — and they **omit large amounts of useful content that the source plan does contain**. An engineer (or agent) picking up a story today must return to `plan_docs/development-plan.md` for the actual code, config, naming rules, prompts, and quality gates. The fix is to make body rendering **plan-faithful** (carry real content, forbid filler), and the measured cost of doing so is **≈ zero** (rich bodies are slightly *smaller* than the current thin ones; runtime is gh-API-bound, not body-bound — see §5).

---

## 2. Defect inventory

### P1 — Story bodies contain generic boilerplate filler (the Plan section and others)

Audited against the live issue #3 (`Story 1.1: Repository Bootstrap (T-0.1)`); identical across all 22 stories:

| Story body section | Content | Verdict |
|---|---|---|
| Title / Objective / In-Scope / Acceptance Criteria / Dependencies | per-task, from the plan | ✅ real |
| Scope → Out of Scope | "Features deferred to other stories (see dependencies)" | ❌ filler — says nothing |
| **Plan** | "Implement per the AC… / Add tests… / Verify build…" | ❌ **filler — the big one; zero task-specific info** |
| Validation Plan (2nd bullet) | "dotnet build exit 0; dotnet test green…" | ❌ filler |
| Validation Commands | `dotnet build` / `dotnet test` | ❌ filler (and misleading — T-0.1 has no test project yet) |
| Implementation Notes (policy tail) | "Conventional Commits… / CancellationToken… / Never hardcode secrets" | ❌ generic global policy |
| Test Strategy | repeats the per-task note | ⚠️ redundant |

**Consequence:** the `Plan` section — the actionable "how to build it" — is empty of real content. The plan *does* have per-task implementation detail (a `Reference:` code/config block on several tasks) that was dropped instead of placed here.

### P2 — Epic bodies contain identical boilerplate across all 7 epics (one section actively wrong)

Audited `epic-1.md` and `epic-4.md` (structurally identical). Real per-epic content: Title, Overview, Goals, Epic Stories, Implementation Plan, Timeline. **Identical boilerplate in every epic:**

- **Brief Technology Stack** — same 5 lines in all 7 epics, and **actively wrong** for non-AI epics: `epic-1.md` (Environment & Foundation) says *"AI/Runtime: Microsoft.SemanticKernel (epics 4); Apify (epic 3)"* — irrelevant to that epic.
- **Validation Plan / Acceptance Criteria / Risk Mitigation table / Repository Branch / Implementation Notes** — generic, copy-pasted into every epic.
- The plan's per-phase risks (§14) are **not** surfaced per-epic; instead every epic gets the same 2 generic risk rows.

### P3 — Substantial plan content was not transferred to any issue

The plan (`plan_docs/development-plan.md`) contains material the skill dropped entirely. Confirmed present in the plan, absent from the generated issues:

| Plan section | Content | Disposition in generated issues |
|---|---|---|
| Per-task `Reference:` blocks | T-0.1 `Directory.Packages.props` XML (exact versions); T-0.2 AppHost `Program.cs`; T-3.3 KNN SQL; T-3.4 output JSON schema | ❌ dropped (belongs in each story's Plan) |
| `⚠ Agent Note` (T-2.2) | "Verify Apify actor IDs against live Apify Store before committing" | ❌ dropped |
| §2 Agent Operating Principles (R1–R8) | mandatory rules: no out-of-scope edits, exact versions, XML docs + unit test on every public method, CancellationToken on all async I/O, no hardcoded secrets, record/class/interface conventions, conventional commits, stop on ambiguity | ❌ dropped (cross-cutting quality rules) |
| §3 exact package-version table | Aspire.Hosting 8.2.2, Npgsql 8.0.10, Pgvector.EntityFrameworkCore 0.2.0, Hangfire.Core 1.8.14, Refit.HttpClientFactory 7.2.1, FluentValidation 11.10.0, … | ⚠️ summarized in Plan body, not verbatim |
| §4 repository layout | file-level tree (every entity, value object, repository, job, page, endpoint, prompt file) | ⚠️ collapsed to a 3-line summary in Plan body |
| §5 Naming & Code Conventions | namespace `GapMiner.{Layer}.{Feature}`, entity/repo/command/endpoint-route/column/Redis-key conventions | ❌ dropped entirely |
| §13 Prompt Engineering Library | full text of `MapReviewsPrompt.txt`, `ReduceGapsPrompt.txt`, `EmbeddingPrompt.txt` | ❌ dropped (critical for the AI-worker stories 4.2/4.4) |
| §15 Definition of Done (global) | 7-point DoD: build 0 warnings, tests green (affected + Integration), StyleCop + SonarAnalyzer clean, XML docs, conventional commit, PR desc with task id + test evidence | ❌ dropped |
| §17 Handoff Checklist (reviewer) | no hardcoded secrets, no invented actor IDs, no vibe-coded anti-patterns, reversible migrations, prompts as files, coverage ≥ 80% | ❌ dropped |
| §18 Escalation Protocol | never-guess list (actor IDs/schemas, LLM keys/endpoints, marketplace policy, security design); ADR-on-ambiguity process | ❌ dropped |
| §16 Parallel Execution Map | Groups A–G / Gates 1–3 | ⚠️ gates → milestones; group structure not surfaced |

**Answer to "is there useful information in the development plan you didn't include?":** **Yes — a lot.** Most impactful for dev-readiness: the per-task `Reference:` code snippets (P1/P3), the §13 prompt texts, and the cross-cutting quality gates (§2/§15/§17/§18) plus §5 naming conventions.

### P4 — Plan body (#1) is mostly faithful, with two condensations

For completeness: the Plan body is largely real (Overview, Goals, Tech Stack, Architecture, Risks from §14, Timeline, Metrics). Only two condensations: the §4 file-level tree → 3-line summary, and the §3 exact-version table → summarized prose. These are defensible at the Plan level but would be more useful verbatim.

---

## 3. Root cause

The skill and its templates **do not prescribe what plan content must be transferred into issue bodies, nor forbid generic placeholder text**. The body renderers are composed by the agent on each run; with no "must carry the plan's `Reference:` snippets" rule and no "no identical-across-issues filler" rule, the renderer defaulted to template-shaped boilerplate for the sections the plan didn't obviously map into. The information was available in the plan; the transfer contract was underspecified, so it didn't happen.

This is the same class of gap as the Phase→Epic mapping ambiguity (companion doc §3): the skill leaves a load-bearing decision to inference, and inference produced filler.

---

## 4. Fixes

### F1 — Story body spec (plan-faithful, no filler)

- **`Plan` section must be plan-derived.** When the task has a `Reference:` block, include it **verbatim** in a fenced code block (e.g. ` ```xml `, ` ```csharp `, ` ```sql `) under a `### Reference (from plan T-x.y)` sub-heading. Then list **concrete implementation steps** derived from the task — not the generic "Implement / Add tests / Verify" trio.
- **Drop or real-fill the filler sections.** Remove the content-free *Out of Scope* line, the generic *Validation* bullet, the misleading generic *Validation Commands*, and the global-policy tail of *Implementation Notes*. If a section has nothing task-specific to say, **omit it** rather than paste boilerplate.
- **Forbid identical-across-issues filler.** No two stories should share a body section verbatim unless that section is genuinely common (and if common, it belongs in one canonical place, not copied 22×).

### F2 — Epic body spec (per-epic, not copied)

- **Brief Technology Stack** must reflect *that epic's* stack (epic 4 = SemanticKernel + embeddings; epic 3 = Apify + Refit + Polly; epic 6 = Blazor + charting lib) — not the same 5 lines in every epic.
- **Risk Mitigation** must pull the relevant rows from the plan's §14 for that phase (e.g. epic 4 → "LLM output violates JSON schema", "Semantic Kernel API change", "Context-window overflow"; epic 3 → "Apify actor id incorrect", "Agent hallucinating Apify response shapes").
- Drop the generic *Validation Plan / Acceptance Criteria / Repository Branch / Implementation Notes* boilerplate, or make them epic-specific.

### F3 — Plan-content transfer manifest (make the contract explicit in the skill)

Add a table to the skill prescribing where each plan element lands:

| Plan element | Target |
|---|---|
| Per-task `Reference:` snippet | Story `Plan` section, verbatim |
| Per-task `⚠ Agent Note` | Story `Implementation Notes` |
| §2 R1–R8 + §15 DoD + §17 handoff checklist + §18 escalation | One canonical **Development Standards** block (Plan body, or a pinned issue) referenced by every story — not copied into each |
| §5 Naming & Code Conventions | Plan body *Conventions* section (or epic context) |
| §13 prompt texts | The relevant stories' `Plan` (4.2 EmbeddingPrompt; 4.4 Map/Reduce prompts), verbatim |
| §3 exact versions + §4 file tree | Plan body, verbatim (not summarized) |
| §14 risks | Split: relevant rows per epic; full table on Plan body |
| §16 Parallel Execution Map | Encoded as blocked-by edges (already); optionally summarized on Plan body |

### F4 — Assert no-filler in the DryRun preview

Add a DryRun check that flags any body section whose text is byte-identical across ≥ 3 issues (a strong filler signal), so the run fails loudly in preview rather than shipping boilerplate.

---

## 5. Performance impact of the fix (measured)

**Concern:** does generating all 22 stories with rich (verbatim-`Reference`) content add inordinate time to skill execution?

**Experiment:** generated rich bodies for Epic 1 (3 stories, incl. the 2 tasks that have `Reference:` snippets) + Epic 2 (4 stories, no snippets) = 7 stories, then extrapolated.

```text
Body size (bytes):                THIN (current)   RICH (verbatim)   delta
  story-1.1 (has XML ref)              1762             2281          +519
  story-1.2 (has C# ref)               1719             2167          +448
  story-1.3 (no ref)                   1526             1048          -478
  story-2.1 .. 2.4 (no ref)         1710–1972        1338–1848       -124..-372
  ─────────────────────────────────────────────────────────────────────────
  TOTAL (7 stories)                   12449            11905          -544  (-4%)
  average per story                   1778 B           1700 B          -4%
```

**Result: rich bodies are ~4–5% SMALLER, not larger** — because the real content (verbatim snippet + concrete steps) *replaces* the boilerplate filler rather than adding to it. Stories *with* a `Reference:` snippet grow ~+480 B; the five without shrink (filler removed).

**Runtime cost — none measurable:**

- Body **render**: ~0.40s for 7 stories (PowerShell startup-dominated; the rendering itself is milliseconds). Projected for 22: still ~0.4s.
- **gh API stage** (the part the user actually waits for): on the india89 run this was **8 min 15 sec across 435 API calls** (0 failures). This stage is **call-count-bound, not body-bound** — 30 issues × (create + link + fields + deps) drives the count; body richness does not change it, and payload size is ~unchanged (rich ≈ thin in bytes).
- **LLM composition cost** (the agent authoring the driver each run): neutral-to-cheaper — rich bodies are net-smaller, and verbatim snippets are copied, not authored.

**Conclusion:** the fix adds **≈ zero** to skill execution time. The 8-minute runtime is gh-API-bound; rich, plan-faithful bodies are free in runtime terms and neutral-to-cheaper in composition terms. There is no performance reason to keep the thin/boilerplate bodies.

---

## 6. Recommended upstream actions

- [ ] **F1** Add a story-body spec to the skill: `Plan` must carry the task's `Reference:` snippet **verbatim** + concrete steps; forbid identical-across-stories filler; omit empty sections instead of pasting boilerplate.
- [ ] **F2** Add an epic-body spec: per-epic tech stack + per-epic §14 risks; drop the generic boilerplate (and the wrong cross-epic "AI/Runtime" line).
- [ ] **F3** Add the **plan-content transfer manifest** (§4 table) to the skill so the agent knows exactly where each plan element must land.
- [ ] **F4** Add a DryRun assertion that flags any body section byte-identical across ≥ 3 issues (filler detector).
- [ ] **F3-data** Land the §2/§15/§17/§18 quality gates and §5 naming conventions in one canonical location (Plan body *Development Standards* or a pinned issue) so they travel with every clone without being copied per-story.
- [ ] Regenerate the india89 story + epic bodies (idempotent via `ensure-issue.ps1 -UpdateBody`) once the upstream spec lands, to replace the current filler.

---

## 7. Evidence artifacts (this repo, for reference)

- Live issues: `https://github.com/intel-agency/gap-miner-v2-india89/issues/1` (Plan), `…/3` (sample story).
- Generated bodies (thin): `/tmp/kilo/gap-miner-v2-india89/bodies/` (driver: `/tmp/kilo/gap-miner-v2-india89/driver.ps1`).
- Rich-body experiment: `/tmp/kilo/gap-miner-v2-india89/diag/rich-gen-experiment.ps1` → `/tmp/kilo/gap-miner-v2-india89/diag/rich-bodies/`.
- Run forensic log: `gh-init-gap-miner-v2-india89-20260720T184908Z.log` (435 calls, 0 failures, 8m15s).

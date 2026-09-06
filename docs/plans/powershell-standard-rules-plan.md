# Plan: PowerShell Engineer Standard as a Rules File Hierarchy

Status: CONFIRMED 2026-08-16 — **Option A+** (vendored hierarchy + skill-wrapped split/refresh, no new repo). `powershell-script-expert` subagent confirmed with dual definitions (`.kilo/agent/` + `.opencode/agents/`). Ready for implementation.
Date: 2026-08-15 (confirmed 2026-08-16)
Source site: <https://www.powershellengineer.com/standard>

## Goal

Turn the PowerShell Engineer Standard (v1.1.1) into a discoverable markdown rules
hierarchy consumable by agents working in this repo and its clones, with one main
rule file (`.agents/rules/powershell.md`) that indexes the rest.

## Source findings

1. **No HTML conversion is needed.** The site publishes the full Standard as clean
   markdown at <https://www.powershellengineer.com/AGENTS.md> (a `CLAUDE.md` shim
   also exists). We fetch markdown, not scrape HTML.
2. **License:** MIT — "Copy it, fork it, adapt it to your house rules. Attribution
   appreciated, not required." We will attribute anyway (maintainer Jim Tyler,
   Microsoft MVP; v1.1.1; not affiliated with Microsoft).
3. **Size/shape:** ~1,170 lines, 21 numbered sections (§0–§20) with subsections,
   plus *Definition of done*, *Lineage*, and *Deeper guidance*. Too big for one
   rule file; natural `## `/`### ` section boundaries make a mechanical split
   reliable.
4. **Section inventory** (for the split mapping below): §0 Non-negotiables (+0.1
   Do-not-invent-API-surface) · §1 Canonical shape · §2 Naming · §3 Parameters &
   validation (+Completion, Dynamic parameters) · §4 Splatting · §5 Output &
   pipeline · §6 Error handling (+Strict mode) · §7 ShouldProcess · §8 Help
   quality bar (+External help) · §9 Pester v5 · §10 Module structure (+Compiled
   components, Scaffolding, Dependencies, Ecosystem frameworks) · §11 Performance
   (+Parallelism) · §12 Security (12.1–12.4) · §13 Cross-platform · §14 Classes ·
   §15 Output/logging/accessibility (15.1–15.2) · §16 Localization · §17 Style &
   file conventions (17.1–17.2) · §18 GUIs (18.1–18.5) · §19 Prose (19.1–19.5) ·
   §20 Files & reports (20.1–20.5).

## Proposed hierarchy (applies to every storage option)

Main file `.agents/rules/powershell.md` is a **thin index**: source metadata
(version, upstream URLs, MIT attribution), the §0 non-negotiables checklist
inlined (it is the always-load contract), a topic table with "load this file
when..." triggers, and the house-overrides precedence note. Topic files hold the
verbatim Standard text, grouped by when an agent needs them:

| File | Standard sections | Load when... |
|---|---|---|
| `powershell/00-non-negotiables.md` | §0, §0.1 | always (also inlined in index) |
| `powershell/01-function-authoring.md` | §1–§4 | writing any function (shape, naming, params, splatting) |
| `powershell/02-pipeline-errors-safety.md` | §5–§7 | emitting output, error handling, `-WhatIf`/`-Confirm` |
| `powershell/03-help-and-prose.md` | §8, §19 | writing comment-based help, comments, READMEs |
| `powershell/04-testing-pester.md` | §9 | writing or reviewing Pester tests |
| `powershell/05-modules-packaging.md` | §10, §14, §18 | module layout, classes, GUIs |
| `powershell/06-performance.md` | §11 | perf-sensitive code, parallelism |
| `powershell/07-security.md` | §12 | secrets, untrusted input, supply chain, execution context |
| `powershell/08-platform-style-encoding.md` | §13, §16, §17 | cross-platform code, localization, formatting/encoding |
| `powershell/09-output-logging-files.md` | §15, §20 | logging, CSV/JSON/HTML/markdown export |
| `powershell/99-definition-of-done.md` | *Definition of done*, *Lineage*, *Deeper guidance* | DoD checklist, provenance, deeper guidance |

*Definition of done*, *Lineage*, and *Deeper guidance* fold into
`powershell/99-definition-of-done.md`. Each
topic file keeps original section numbers in headings (e.g. `## §5 Output and
the pipeline`) so citations stay stable against upstream.

## House-rule harmonization

This repo already has PowerShell constraints in `.agents/rules/coding-style.md`
and memory (strict-mode `PSObject.Properties` null guard, comma-guard for array
returns, `throw` over `Write-Error` + `exit 1`, >85% coverage). The Standard
aligns with all of them (it mandates `Set-StrictMode -Version Latest`, catchable
terminating errors, Pester). Precedence rule, stated in the index: **house rules
override the Standard where they conflict; the Standard governs everything
else.** The Standard itself defers to "explicit instruction from the user",
which this mirrors.

## Decision: Option A+ (A with the split/refresh script)

Vendored hierarchy in this repo **plus** the skill script
`.agents/skills/update-powershell-standard/scripts/update-powershell-standard.ps1`, which
fetches the upstream monolithic `AGENTS.md`, splits it on section boundaries, and writes
the topic files. Rationale:

- 60 KB is negligible for the repo, and agents reach it through progressive disclosure
  (index → one topic file), so size never hits the context window wholesale.
- The script removes Option A's real con (manual re-split / drift): refresh is a
  deterministic regeneration, run on demand — upstream updates are infrequent and small,
  so no scheduling needed. The script can compare the upstream version line (e.g.
  `v1.1.1`) against the version recorded in the index and no-op when unchanged.
- It drops Option C's costs (second copy, sync discipline, a repo to maintain): the single
  source of truth is **upstream itself**; our hierarchy is a derived, regenerable artifact.
  That is strictly better than mirroring our own canonical repo.

**Design consequence — generated files are not hand-edited:** topic files under
`.agents/rules/powershell/` carry a generated-by header and are replaced wholesale on
refresh. House-specific content (local overrides, precedence notes, extra checklists)
lives only in the hand-maintained index `.agents/rules/powershell.md` and existing rule
files, never in the generated topic files.

Options B and C remain documented below for the record.

## Storage options (considered)

### Option A — Full hierarchy vendored in this repo

`.agents/rules/powershell.md` + `.agents/rules/powershell/*.md`, authored once
by splitting the upstream `AGENTS.md`. No other repo involved.

| Pros | Cons |
|---|---|
| Zero-latency local reads; agents always load rules | ~60 KB of third-party content vendored into the template |
| Works offline and in every clone (Class 1 travels) | Refresh on upstream version bumps is a manual re-split chore |
| No new repo, no sync machinery | Template repo carries content not authored here |
| Matches existing `app-stacks/` subdirectory pattern | Drift from upstream is possible and undetected |

### Option B — Public GH repo hosts hierarchy; only the index lives here

New public repo (e.g. `nam20485/powershell-engineer-standard`) holds the split
topic files; `.agents/rules/powershell.md` links to raw.githubusercontent URLs.

| Pros | Cons |
|---|---|
| Template stays lean (~1 index file) | **Every rule consult is a network fetch** — slow, and fails offline/air-gapped |
| Single canonical copy, reusable from any other repo | Clones depend on external repo availability |
| Version bumps centralized in one place | Agents skip costly fetches → weaker rule compliance (defeats the purpose of rules) |
| Public hierarchy aids human discovery, as requested | One more repo to maintain |

### Option C — Hybrid: public canonical repo + local mirror + refresh script (recommended)

Public repo holds the hierarchy (as in B). This repo mirrors the split files at
`.agents/rules/powershell/` — the mirror **is** the working copy agents read —
and a refresh script re-syncs it. This is exactly the existing
`nam20485/agent-instructions` → `local_ai_instruction_modules/` →
`scripts/update-remote-indices.ps1` pattern, so it introduces no new concept.

| Pros | Cons |
|---|---|
| Local zero-latency reads (A's main pro) | Two copies exist; sync discipline required |
| Canonical public hierarchy for discovery + reuse (B's main pro) | New public repo still needed |
| One-command refresh; mirror is regenerable, drift-free | Slightly more machinery than A |
| Precedent already proven in this repo | — |

## Proposed addition: `powershell-script-expert` subagent

Dual agent definitions, one per runtime:

- `.kilo/agent/powershell-script-expert.md` — Kilo project agent (none exist yet;
  `.kilo/agent/*.md` is the designated location).
- `.opencode/agents/powershell-script-expert.md` — opencode agent matching the existing
  eight (`.opencode/agents/` already defines `orchestrator`, `developer`,
  `code-reviewer`, `planner`, `qa-tester`, `researcher`, `team-lead`,
  `team-orchestrator` in YAML-frontmatter format: `description`, `mode: subagent`,
  `model`, `color`, `temperature`, `permission` block). Permissions for this agent:
  read/glob/grep/list/webfetch/websearch allow (research + upstream fetch), edit allow
  (writes PS code), bash allow with destructive denies, skill allow (invokes the update
  skill).

Both definitions carry the same body — the only place with budget to front-load
PowerShell-specific context: the §0 non-negotiables checklist inlined, orientation to
the rules hierarchy, the house-overrides precedence, Pester/PSScriptAnalyzer workflow,
and the repo's PS conventions (strict-mode null guards, comma-guard, `throw` over
`Write-Error`). General agents (`orchestrator`, `developer`) stay lean and link out,
which is correct.

Scope (specialist pattern, sibling of `code-reviewer`/`researcher`):

- **Write** non-trivial PowerShell scripts/functions to the Standard
- **Plan** PowerShell architecture (module layout, function design)
- **Review** existing PowerShell code against the Standard + house rules
- **Debug** existing PowerShell code
- **Research/investigate** PowerShell behavior and report back (e.g. verify a cmdlet's
  parameter surface — §0.1's `# VERIFY:` discipline)
- **Maintain the corpus**: run the `update-powershell-standard` skill on version bumps
  and update the index metadata

Delegation threshold (to be recorded in `.agents/rules/delegation.md` and both
orchestrator definitions): delegate **non-trivial** PowerShell work (new script,
review pass, debugging session, research question, corpus refresh); handle trivial
one-liner edits inline. Subagents pay a handoff cost — context must be packaged into
the prompt and results return as one message — so gating every tiny PS touch through it
would be noise.

## Proposed addition: `update-powershell-standard` skill

New skill at `.agents/skills/update-powershell-standard/` wrapping the check-for-updates
+ fetch + re-split operation, per `.agents/rules/skills.md` (AgentSkills-spec-compliant,
self-contained, scripts over prose, `pwsh`, validated with `skills-ref validate`):

- `SKILL.md` — triggers (upstream version bump suspected, periodic check, corpus
  refresh requested), decision guidance (version comparison, what gets regenerated),
  and the call site invoking the script.
- `scripts/update-powershell-standard.ps1` — the split/refresh engine, living inside the
  skill at `.agents/skills/update-powershell-standard/scripts/update-powershell-standard.ps1`
  (relocated from the earlier plan's repo-root `scripts/` to honor
  skills-must-be-self-contained): fetch upstream `AGENTS.md`, parse the version line,
  no-op when it matches the version recorded in `.agents/rules/powershell.md`,
  otherwise split on section boundaries per the mapping table and write the topic
  files with generated-by headers, then report the version delta. Write-only-on-change,
  strict mode, full cmdlet names, Pester-tested (`scripts/tests/`).
- The `powershell-script-expert` agent's corpus-maintenance duty is fulfilled by
  invoking this skill; no agent hand-rolls the refresh.

## Implementation steps (Option A+)

1. **Skill first** `.agents/skills/update-powershell-standard/`: author `SKILL.md` +
   `scripts/update-powershell-standard.ps1` (fetch upstream `AGENTS.md`, compare version
   against the index, split on §0–§20 + Definition-of-done/Lineage/Deeper-guidance
   boundaries per the mapping table, write the 11 topic files with generated-by
   headers, write-only-on-change).
   Running it produces the vendored `.agents/rules/powershell/` files — no hand-splitting.
   Validate with `skills-ref validate`.
2. **Index** `.agents/rules/powershell.md` authored by hand: source metadata (version,
   upstream URLs, MIT attribution), inlined §0 checklist, topic table with load triggers,
   house-overrides precedence, generated-file policy ("don't edit topic files; run the
   `update-powershell-standard` skill").
3. **Subagents** `.kilo/agent/powershell-script-expert.md` **and**
   `.opencode/agents/powershell-script-expert.md` per the sections above.
4. **AGENTS.md + delegation.md:** Rules-list entry for `powershell.md` (two-part brief);
   add `powershell-script-expert` to the delegation taxonomy and `.opencode/agents/`
   orchestrator definition with the threshold above.
5. **House overrides:** cross-link `coding-style.md` ↔ `powershell.md` precedence in one
   line each.
6. **Validation:** markdownlint (`.agents/rules/**/*.md` already in lint globs);
   `skills-ref validate` on the new skill; Pester tests for the split script (>85%
   coverage per repo rules).
7. **Cleanup:** no file deletion needed — the planning-time snapshot this step
   originally referenced (`docs/plans/powershellengineers_AGENTS.md`) was never
   committed to the repo; the skill fetches upstream by URL and Pester tests use
   trimmed local fixtures under the skill's `scripts/tests/`. If a stray local
   snapshot copy ever appears, delete it: the generated `.agents/rules/powershell/`
   files plus upstream itself supersede it, and keeping one would add a third,
   drift-prone copy.

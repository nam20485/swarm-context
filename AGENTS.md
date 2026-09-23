# AGENTS.md

## Repository identity

This repository — **`nam20485/swarm-context`** — is the **parent template**: a fork-style descendant of the `intel-agency/agent-context` template (its `upstream`, push-disabled; base content flows one-way via reviewed PRs) extended with the swarm surfaces (`.zcode/agents` worker definitions, `.agents/rules/swarm.md` + `swarm-workers.md`, the `$swarm` and `swarm-plan` skills). Clones for the swarm-orchestration workflow are minted from it (GitHub template route) by the launcher in `nam20485/swarm-orchestration-service`, so when the user refers to "the parent template", "the swarm seed", or "a swarm-context clone", treat it as a repo stamped from this one.

## Memory and Rules

This project uses a dynamic memory and rules system under the `.agents/` directory — the **single source of truth** for project-specific decisions, conventions, and history.

**ALWAYS consult `.agents/` before starting work** — do not assume; look it up.

### Memory

Memory is the project's durable context, located at `.agents/memory.md`. It has four sections:

- **Current Activity** — the active project and its in-progress work items. Move items to Completed when done.
- **Completed Work Items** — finished work, organized by project.
- **Decisions** — design decisions, trade-off choices, and their rationale.
- **Remember To Do** — deferred tasks and future changes to plan when current work is done.

### Rules

Rules dictate coding conventions, tools, validation, testing, source control, delegation, and work practices. Files live under `.agents/rules/`, one per subject:

- **Tools**: `.agents/rules/tools.md`
- **Validation**: `.agents/rules/validation.md`
- **Source Control**: `.agents/rules/source-control.md`
- **Delegation**: `.agents/rules/delegation.md`
- **Practices**: `.agents/rules/practices.md`
- **Coding Style**: [`.agents/rules/coding-style.md`](.agents/rules/coding-style.md) — coding conventions including Simplicity First and Goal-Driven Execution. Core rule: write all scripts in cross-platform PowerShell (`pwsh`) unless a task specifically requires another language.
- **Skills**: [`.agents/rules/skills.md`](.agents/rules/skills.md) — skill creation conventions. Core rules: all skills must be strictly compliant with the [Agent Skills spec](https://agentskills.io/specification) — always review the current spec before creating or modifying any skill; and prefer scripts under `scripts/` over prose steps for any repeatable operation so the skill produces deterministic output across runs.
- **Scripts**: [`.agents/rules/scripts.md`](.agents/rules/scripts.md) — repo-root `scripts/` inventory (auth helpers, `import-labels.ps1` for label sync, `query.ps1` as the canonical PR review-thread manager, dispatch-issue creator, permission verifier, remote-index regenerator). Read each script's header + `param()` block for authoritative docs.
- **Agent-Instructions Modules**: [`.agents/rules/ai-instructions-modules.md`](.agents/rules/ai-instructions-modules.md) — lookup tables for `nam20485/agent-instructions` workflow assignments and dynamic workflows, stored at `local_ai_instruction_modules/` (hard-coded path; refreshed by `scripts/update-remote-indices.ps1`).
- **Kilo Code Docs**: [`.agents/rules/kilo-code-docs.md`](.agents/rules/kilo-code-docs.md) — consult the official Kilo docs site for any question about, or instruction to configure/setup, the Kilo Code CLI or IDE extension. Access points: full-docs LLM dump at `https://kilo.ai/docs/llms.txt` and per-page raw Markdown at `https://kilo.ai/docs/api/raw-markdown?path=<url-encoded-path>`.
- **Qwen Code Docs**: [`.agents/rules/qwen-code-docs.md`](.agents/rules/qwen-code-docs.md) — consult the official Qwen Code docs for any question about, or instruction to configure/setup, Qwen Code usage, features, or settings. Access points: markdown `llms.txt` index at `https://qwenlm.github.io/qwen-code-docs/llms.txt` (index only, no full dump) and per-page raw Markdown at `https://raw.githubusercontent.com/QwenLM/qwen-code/main/docs/<path>.md`.
- **App Stacks**: pre-defined language and tech stack profiles in `.agents/rules/app-stacks/`. Each file is a stack definition named by slug ID, referenced from app development/implementation plans to specify the language, tech stack, tools, and packages to use. Available stacks:
  - `dotnet-aspire-aspnet-blazor` — .NET Aspire + ASP.NET Core + Blazor WASM
  - `dotnet-avalonia-xplatform-desktop` — .NET Avalonia cross-platform desktop
  - `python-uv-fastapi-vite` — Python (uv) + FastAPI + Vite frontend
- **Swarm**: [`.agents/rules/swarm.md`](.agents/rules/swarm.md) — goal-driven agent swarm on the ZCode harness: primary-session orchestrator + narrowly single-purpose least-privilege worker types, `$swarm` skill entry point with an optional interactive planning frontend (`/swarm plan` → the `swarm-plan` skill: plan → goal approval → gh-issue-tracking-init → swarm), shared worker rules in `.agents/rules/swarm-workers.md`, run state under gitignored `.swarm/<run-id>/`. The roster is mirrored on opencode as `.opencode/agents/swarm-*.md` with `default_agent: swarm-orchestrator` (the king — dispatch sessions land on him; per the ACP parity rule the two sets stay word-for-word mirrored in rules, each in its harness's native frontmatter).

**IMPORTANT:** Check the relevant rules file before working on any file or performing implementation.

When relocating content into a rules file, the AGENTS.md section that replaces it should become a two-part brief: 1. **Title**: a title describing the type of content the linked file holds (not just its subject name)
2. **Summary**: a summary previewing the 1–2 most important actual items from the file, abbreviated in-context.

### Updating Memory and Rules

**ALWAYS update as you go — never wait until you are done with all work.**

- Update the memory file's **Current Activity** section as you progress; move completed items to **Completed Work Items**, move the **Project** header down when you complete the **entire** project.
- Update the relevant rules file when you learn new conventions, requirements, or guidelines. If a rules file does not exist for a subject, create it.

---

## Validation

Detailed validation, testing, and TDD rules live in [`.agents/rules/validation.md`](.agents/rules/validation.md). Test coverage must be maintained > 85%. Includes repo-verified Pester 5 gotchas (single `BeforeAll` per `Describe`; no backtick fences inside `@"…"@` here-strings) — read before writing Pester tests.

## CI/CD Pipeline Requirements

CI/CD pipeline requirements — mandatory test, coverage, and scanning steps plus strict version pinning — live in [`.agents/rules/ci-cd.md`](.agents/rules/ci-cd.md). Pipelines must enforce > 85% coverage and generate an HTML coverage report.

## Committing

Source control rules — safe commits, workflow monitoring, branching, and pull requests — live in [`.agents/rules/source-control.md`](.agents/rules/source-control.md). Always run the `/safe-commit` skill before committing.

## Delegation & Orchestration

Delegate work to the appropriate subagent and orchestrate multi-agent tasks using the smallest layer that fits the scope. Structure every task input with four elements — Goal, Context, Constraints, Done when. Detailed delegation and orchestration rules live in [`.agents/rules/delegation.md`](.agents/rules/delegation.md).

## Orientation

Always orient to the project's history and current state before starting any work — memory, plans, pending changes, and recent commits. Detailed orientation steps live in [`.agents/rules/practices.md`](.agents/rules/practices.md).

## Planning, Investigation & Making Changes

Always plan non-trivial tasks before starting, investigate root causes using first-hand sources, and make the smallest surgical changes possible. Detailed rules for the full lifecycle live in [`.agents/rules/practices.md`](.agents/rules/practices.md).

## Coding Style Discipline

**ALWAYS load and apply these guidelines whenever making or planning code changes.** Write minimum code that solves the problem (no speculative features or unnecessary abstractions), define verifiable success criteria before implementing, and loop until verified. Detailed rules live in [`.agents/rules/coding-style.md`](.agents/rules/coding-style.md).

## Tool Usage

Detailed tool guidance and decision points live in [`.agents/rules/tools.md`](.agents/rules/tools.md).

- **Sequential-Thinking and Memory knowledge-graph MCP — use discontinued (2026-09-12)**: both were deemed redundant and inferior to the model's builtin reasoning and memory; their server defs are removed and this note replaces the former usage guidance. Do not call their tools or re-add them.
- **Semantic Search (Codebase Indexing)** — finds code by meaning via AI embeddings; prefer as the first probe in unfamiliar code areas.
- **Web & Repository Research (Z.AI MCP)** — remote web search (`webSearchPrime`), URL reader (`webReader`), and public GitHub repo reader (`zread`).
- **Exa Search (MCP)** — neural web search, code-context lookup, and site crawling; complement to Z.AI.

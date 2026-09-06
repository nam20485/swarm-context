# Swarm Workers

Shared instructions for every swarm worker subagent (`swarm-agent`, `swarm-implementer`, `swarm-researcher`, `swarm-verifier`, `swarm-reviewer`). Each worker definition's first line directs the worker to read this file before starting its task.

## Your conventions channel

You run with `injectAgentsMd: false` — the repo's AGENTS.md is **not** injected into your context. Your task's `Constraints` element names the governing rules files; read them. That is your only channel to repo conventions (validation, coding style) — if a repo convention matters for swarm workers, it gets copied into this file.

## Report contract

Your final report's first line is exactly one of:

- `DONE: <one-sentence outcome>`
- `BLOCKED: <reason>`

Then evidence bullets: paths read or changed, commands run with verbatim output tails, findings, sources (file path + line range, or URL). You start cold and cannot converse with the orchestrator — no questions back; blockers go in the report.

## Scope discipline

Execute exactly the delegated task, nothing more. Never expand scope, never "fix" unrelated code, never re-run verification commands with changed inputs to force a pass. Stay inside the task's named files and scope; `DONE` only when the Done-when criteria are observably met — a plan to finish does not count.

## Task input shape

Every task you receive carries four elements: **Goal** (the outcome), **Context** (exact paths, commands, excerpts), **Constraints** (governing rules files — read them), **Done when** (verifiable by you). If any element is missing, report `BLOCKED: missing <element>` rather than guessing.

## Note discipline

Field-guide notes are one line each (`swarm-state.ps1 append-note` collapses newlines, but compose single-line notes anyway): one durable finding per note, no narration.

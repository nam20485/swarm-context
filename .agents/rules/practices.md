# Orientation, Planning, Investigation, and Making Changes

The disciplined engineering lifecycle: orient to context before starting, surface assumptions and tradeoffs before acting, investigate root causes using first-hand sources, and make the smallest surgical changes possible.

## Orientation

When starting a new project, session, task, or answering questions, always orient yourself to the project's history and current state first.

**Do not perform any work or proceed with any tasks without understanding the history and context.**

Inspect the following to orient yourself:

- **Memory Tools** — query the Memory knowledge-graph: `memory_search_nodes` to find relevant entities by keyword, `memory_read_graph` to browse the whole graph, and `memory_open_nodes` to open specific entities.
- **Memory Context File** — read `.agents/memory.md` (Current Activity, Completed Work Items, Decisions, Remember To Do) for the project's current state and history.
- **Plans** — glob and read `plan_docs/`, `docs/plans/`, and `docs/` for existing plans, specs, and design docs relevant to the task.
- **Uncommitted changes** — run `git status` and `git diff` to see pending work in the working directory.
- **Recent commits** — run `git log --oneline -10` to see the latest work and conventions in the current branch.

## Planning

- Always create a plan before starting any non-trivial task (e.g. >= 3 steps or >= 5 minutes of work).
- Present plans for approval before starting any non-trivial task.
- Always use TODO lists to track work to be done.
- Mark TODO items as complete when they are done.
- Present summary after completing all plans/tasks.

### Think Before Coding

Before implementing, apply these checks:

- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them — don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## Investigation

- Never guess at the cause of an issue.
- Always investigate the issue using first-hand sources, i.e. logs, code, output.
- Do not make or report assertions without specific details, i.e. line numbers, files, log messages, etc., to back up your claims.
- Do not determine or start implementing a solution until you have decisively found the root cause.

## Handling Command Failures

When a CLI command fails, before retrying:

1. Read the error message and its context for hints.
2. Verify command syntax (`--help`, `Get-Help`, or tool docs).
3. Inspect usage examples and construct a corrected command from careful analysis.
4. For complex commands, break them into smaller parts and test each.

**Do not keep retrying the same command without understanding the issue.** Diagnose and fix the problem before retrying. If the command still fails after up to 3 informed attempts, search the web for the error message / docs before retrying again. Once a working command is found, document it where appropriate for future runs.

Exit-code checks: `$?` (bash success/fail) or `$LASTEXITCODE` (pwsh / native-command exit code).

## Making Changes

**Touch only what you must. Clean up only your own mess.**

- Always make the smallest most surgical change possible.
- Only make changes that are necessary to fix the issue at hand.
- Ignore areas that are not relevant to the current task.
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it — don't delete it.

When your changes create orphans:

- Remove imports, variables, and functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.
- Every changed line should trace directly to the user's request.

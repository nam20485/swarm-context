---
name: safe-commit
description: >-
  Runs scan-uncommitted-secrets, validate.ps1, then groups outstanding changes
  into logical commits with meaningful messages. Use when the user asks for
  safe-commit, safe commit, commit changes safely, or grouped commits after
  validation.
disable-model-invocation: true
---

# Safe Commit

Commit outstanding work only after a clean secret scan and passing validation, split into focused commits by concept.

> **Decisiveness defaults — apply these without deliberating.** They exist so routine file-by-file
> calls don't eat a turn. Always check the target repo's `AGENTS.md` first for repo-specific
> asset/hygiene policy; it overrides these defaults.
>
> | Decision | Rule |
> |----------|------|
> | Binary asset (model/checkpoint) | Follow the **repo's established pattern**. If the repo commits that asset type (e.g. `.onnx`), stage it; if it was previously excluded (e.g. `.pt` not in the model commit), **gitignore** it. Never ask. |
> | Tie-breaker for any non-runtime binary | Prefer **gitignore** (reversible) over committing (multi-MB history bloat is not). |
> | Machine-local state (`.idea/`, `.vs/`, `*.user`, `bin/`, `obj/`, `node_modules/`, OS noise, credentials) | **Never** commit, **never** deliberate → gitignore (hygiene commit) or skip silently. |
> | Grouping | Split by **operation type / subsystem** automatically (a deletion ≠ an addition = separate commits). Don't debate "one theme or two." 1–6 groups; prefer more, smaller. |
> | Commit order | Not worth deliberating: deletions → additions → config/hygiene → docs. Any order is fine. |
> | Message body | Optional; add only for a non-obvious "why." One draft, don't agonize. |
> | Per-file commit/ignore calls | **Do not use the question tool.** Apply this table and report. Stop only for genuine secrets or validation failures. |
> | Re-running | Act only on the current `git status` delta. Do not re-litigate files already decided in a prior turn. |
>
> **Secret hygiene:** never `echo` an env var to test whether it is set (it may hold a secret) —
> use `test -n "$VAR" && echo set || echo unset`. Reference secrets by type/prefix only (`ghp_…`).
> If a secret is ever printed to output or staged, stop committing and flag it for rotation.

## Prerequisites

- User invoked **safe-commit** (this skill is the commit authorization)
- Worktree has uncommitted changes worth committing
- Do **not** commit credential files or hardcoded secrets

## Phase 0 — Remote sync pre-flight (mandatory, read-only)

Detect a diverged branch **now**, not as a rejected push later. Parallel agent sessions (Qwen,
Kilo, OpenCode, droid, VS Code) routinely work the same repo at once, so two sessions can commit
the same file within the same second and one pushes first.

```bash
git fetch --quiet origin 2>/dev/null || echo "fetch unavailable (offline / no remote)"
git status -sb | head -1
```

Read the branch line:

| Suffix | Meaning | Action |
|--------|---------|--------|
| *(none)* | in sync | proceed |
| `[ahead N]` | local commits not pushed | proceed; push only if the user asked |
| `[behind M]` | remote has commits you lack | proceed; surface it in the Phase 6 report |
| `[ahead N, behind M]` | **diverged** | proceed through Phase 5, then reconcile in Phase 5b |

If the divergent commits share an author **and** an identical commit timestamp and touch the same
file, that is the concurrent-session race signature — say so in the report.

**Never block on connectivity.** If `git fetch` fails, or there is no remote/upstream, note it and
continue; this phase must not make the commit gate depend on the network. Record the outcome for
Phase 6 and do **not** reconcile yet — rebase requires a clean tree and the tree is still dirty.

## Phase 1 — Secret scan (mandatory)

Follow [scan-uncommitted-secrets](../scan-uncommitted-secrets/SKILL.md) — this repo carries a
copy in `.agents/skills/scan-uncommitted-secrets/` so child projects are self-contained:

```bash
# Prefer this repo's local copy (child environments may not see user-wide skills).
# Select the path by EXISTENCE, then run it once — never `||`-chain: a non-zero
# exit means SECRETS WERE FOUND and must stop the commit, not trigger a fallback.
SCAN=.agents/skills/scan-uncommitted-secrets/scripts/scan.sh
[ -f "$SCAN" ] || SCAN="$HOME/.agents/skills/scan-uncommitted-secrets/scripts/scan.sh"
bash "$SCAN"
```

Run from the repository root. If neither path exists, stop and report the missing dependency —
do not skip the scan.

**If exit code is non-zero:** stop immediately. Do not stage or commit. Report findings using the scan skill's response format and help remediate.

**If exit code is 0:** proceed to Phase 2.

Also verify secrets stay ignored:

```bash
git add --dry-run -A
```

Abort if dry-run would add **credential files**. Blocked paths (scanner fails these automatically):

| Pattern | Examples |
|---------|----------|
| Env files | `.env`, `.env.local`, `.envrc` |
| Auth / creds | `auth.json`, `secrets.toml`, `credentials.json`, `.pypirc` |
| Keys / certs | `*.pem`, `*.p12`, `id_rsa`, `id_ed25519` |

See [scan-uncommitted-secrets blocked filenames](../scan-uncommitted-secrets/SKILL.md#blocked-credential-filenames) for the full list.

## Phase 2 — Validation (mandatory)

Run the repo's full local validation gate (lint/scan/tests — what CI runs), **regardless of
whether the change "looks" like it needs it**; it is cheap insurance.

```bash
# Prefer the repo's own validation script if it exists:
pwsh -NoProfile -File ./scripts/validate.ps1 -All
```

If there is no `validate.ps1`, run the repo's standard build+test equivalent. For a .NET repo:

```bash
dotnet restore && dotnet build --no-restore -c Release && \
dotnet test --no-build -c Release --settings coverlet.runsettings
```

Always consult the target repo's `AGENTS.md` for the exact gate command.

**If exit code is non-zero:** stop immediately. Do not stage or commit. Report which step failed (from script output), fix issues, and re-run validation until clean.

**If `pwsh` or a tool is missing:** run `pwsh -NoProfile -File ./scripts/install-dev-tools.ps1` if appropriate, or report what the user must install. Do not skip validation unless the user explicitly opts out in the same request.

**If exit code is 0:** proceed to Phase 3.

## Phase 3 — Understand changes

Run in **parallel**:

```bash
git status
git diff
git diff --cached
git log -10 --oneline
```

Read enough of each changed file to assign it to a group. Exclude:

- machine-local editor/agent state directories (e.g. `.idea/`, `.vs/`) — usually skip committing
- Files the user explicitly asked not to commit
- Obvious noise unless the user wants everything committed
- any files already in `.gitignore`

## Phase 4 — Group changes conceptually

Partition files into **1–6 logical groups**. Each group should be one coherent story a reviewer can understand in one glance.

### Grouping heuristics

| Group theme | Typical paths |
|-------------|---------------|
| Container runtime | `Dockerfile`, `compose.yaml`, `.dockerignore`, `scripts/docker-entrypoint.sh` |
| OpenCode server config | `image/opencode.json`, `image/AGENTS.md`, `image/.opencode/` |
| Client scripts | `scripts/prompt.ps1`, `scripts/attach.ps1`, `scripts/common-auth.ps1`, other `scripts/*.ps1` |
| Agent / editor tooling | repo-local agent skill/rules dirs, `.idea/`, `.vs/` (not machine state) |
| Docs / memory | `AGENTS.md`, `plan_docs/`, `README.md` |
| Repo hygiene | `.gitattributes`, `.gitignore`, workspace files |

Rules:

- One file belongs to **one** group (pick the primary purpose)
- Prefer **more, smaller** commits over one large commit when themes differ
- Keep test-only or generated artifacts out unless intentional
- If only one theme exists, a single commit is fine

### Present the plan before committing

Show a short table:

```markdown
| # | Commit message (draft) | Files |
|---|------------------------|-------|
| 1 | ... | file_a, file_b |
| 2 | ... | file_c |
```

Then execute unless the user already constrained grouping in the same request.

## Phase 5 — Commit each group

For **each** group, in dependency-friendly order (infra → config → scripts → docs → tooling):

1. Stage only that group's files (`git add -- <paths>`)
2. Confirm staging: `git diff --cached --stat`
3. Commit with a HEREDOC message

### Commit message style

Match recent repo history: lowercase imperative/descriptive, 1–2 sentences focused on **why**.

```bash
git commit -m "$(cat <<'EOF'
add docker runtime and provider auth synthesis at container start

Generate opencode auth.json from host/CI environment variables before serve.
EOF
)"
```

Guidelines:

- First line ≤ 72 chars when possible; optional body after blank line
- No secrets, tokens, or PII in messages
- Use `add`, `update`, `fix`, `remove` accurately
- Do not bundle unrelated themes in one message

After each commit: `git status --short`

## Phase 5b — Reconcile divergence (only if Phase 0 reported `[ahead N, behind M]`)

Skip this phase when the branch was in sync, merely ahead, or merely behind.

The commits from Phase 5 mean the tree is now clean, so a rebase is possible. First predict
conflicts **read-only**, before touching the branch:

```bash
BASE=$(git merge-base HEAD '@{upstream}')
git merge-tree --write-tree --merge-base="$BASE" '@{upstream}' HEAD >/dev/null 2>&1
echo "merge-tree exit=$? (0 = clean, 1 = conflicts)"
```

**Exit 0 — clean, rebase:**

```bash
git rebase '@{upstream}' && git status -sb | head -1
```

Byte-identical changes on both sides fold automatically in the 3-way merge, so the rebased commit
shrinks to the surviving delta. Re-read it (`git show --stat HEAD`) and confirm its message still
describes what it now contains; if the message is now wrong, ask before rewording (amending needs
the user's amend rules satisfied). Report the old SHA as the reflog escape hatch.

**Exit 1 — conflicts, do not rebase.** Report the conflicting files and hand back to the user. If
a rebase was somehow already started, `git rebase --abort` restores the diverged state exactly.

**Rebase, never merge** — a merge commit to settle a one-file race is history noise. Never
force-push. Never change git config (`pull.rebase`, `pull.ff`) to prevent recurrence; pass the
strategy explicitly on the command line. Do **not** push unless the user explicitly asked — after a
clean rebase the push is a fast-forward, so state that and let the user authorize it.

## Phase 6 — Final report

```markdown
## Safe commit complete

**Scan:** passed (no sensitive content)

**Validation:** passed (`scripts/validate.ps1 -All`)

**Sync:** in sync | ahead N | behind M | diverged (ahead N, behind M) → reconciled by rebase `<old-sha>` → `<new-sha>` | diverged → left for user (conflicts in `<paths>`) | fetch unavailable

**Commits created:**
1. `<hash>` — `<subject>`
2. `<hash>` — `<subject>`

**Skipped (if any):** `<paths>` — `<reason>`

**Remaining uncommitted:** none | `<list>`
```

## Git safety (required)

- NEVER update git config
- NEVER use `--no-verify`, `--no-gpg-sign`, or force push
- NEVER commit hardcoded API keys, passwords, or provider credential files
- NEVER `echo`/print an env var to check if it's set (may hold a secret); use `test -n "$VAR"`. Reference secrets by type/prefix only
- NEVER amend unless user rules for amend are fully satisfied
- NEVER settle a diverged branch with a merge commit — rebase (Phase 5b), dry-run `git merge-tree` first
- Do NOT push unless the user explicitly asks

## Tooling: sequential thinking + memory

- Use the `sequentialthinking` MCP tool whenever the commit/grouping work is non-trivial
  (unknowns, many files, ambiguous binary assets, multi-step fixes). It structures your own
  reasoning; it is not user-facing. Skip it only for a trivial single-group commit.
- Use the `memory` knowledge graph to persist durable repo conventions (asset policy, build gate,
  never-commit paths) so they are not re-derived each session. `memory_search_nodes` at the start
  to recall context; `memory_create_entities`/`memory_add_observations` for new durable facts. Do
  not store ephemeral state or anything already obvious from the code/git.

## Failure handling

| Situation | Action |
|-----------|--------|
| Scan finds secrets | Stop; no commits |
| Validation fails | Stop; no commits; fix and re-run `validate.ps1 -All` |
| Branch diverged (`[ahead N, behind M]`) | Commit normally, then reconcile in Phase 5b — rebase, never merge |
| `git fetch` fails / no remote / no upstream | Note it and continue; never block the commit gate on connectivity |
| Phase 5b `merge-tree` reports conflicts | Do not rebase; report the files; `git rebase --abort` if one started |
| Empty group after exclusions | Skip group |
| Pre-commit hook fails | Fix issue; new commit (do not amend unless allowed) |
| Unclear grouping | Prefer smaller groups; note assumption in report |
| No changes left | Report "nothing to commit" |

## Example grouping (orchestrator-service)

```
1. fix dockerfile node install and multi-stage runtime layout
   → Dockerfile, .dockerignore, scripts/docker-entrypoint.sh, compose.yaml

2. configure opencode image defaults and memory-graph mcp
   → image/opencode.json, image/AGENTS.md, image/.opencode/

3. thin client scripts using host opencode password env
   → scripts/prompt.ps1, scripts/attach.ps1, scripts/common-auth.ps1

4. record workspace conventions in agents memory
   → AGENTS.md
```

Adjust groups to match the actual diff — the example is illustrative, not fixed.

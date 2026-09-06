# Upstream Fix — per-repo scratch workspaces for `gh-issue-tracking-init` runs

**Origin:** `intel-agency/gap-miner-v2-kilo38` · **Date:** 2026-07-18
**Target:** the `gh-issue-tracking-init` skill (`.agents/skills/gh-issue-tracking-init/`) **and** the repo-root tool-usage rules (`.agents/rules/tools.md`)
**Type:** Hygiene / state-isolation convention (no code defect)
**Status:** Fix applied in this repo (which is the upstream template — see propagation note below)

> A composed `gh-issue-tracking-init` run writes several artifacts — a PowerShell
> driver, rendered issue bodies, trace logs, diagnostic scripts. Left loose in a flat
> scratch dir, one repo's run gets mistaken for another's. This fix namespaces all
> per-run scratch **by repo slug** so runs are isolated and cleanup is one command.

---

## TL;DR

| ID | Severity | Type | One-line fix |
|----|----------|------|--------------|
| S1 | **Medium** | State-isolation gap | Namespace all run scratch under `/tmp/kilo/<repo-slug>/` (driver, `bodies/`, `logs/`, `diag/`), created on demand; never write run scratch directly under a flat `/tmp/kilo/`. |
| S2 | Medium | Convention not codified | Add the rule repo-wide in `.agents/rules/tools.md` (applies to every skill/agent) **and** gh-init-specific in `SKILL.md` ("Delegation performance"). |

---

## Symptom (the incident)

After the `gap-miner-v2-charlie53` run (the upstream driver-fixes forensic, [`docs/plans/.completed/upstream-driver-fixes.md`](./.completed/upstream-driver-fixes.md)), the following sat **loose in a flat `/tmp/kilo/`**:

```
/tmp/kilo/
├─ gapminer-gh-init-driver.ps1   # 42 KB — charlie53's composed driver (hardcodes charlie53 + its node set)
├─ gapminer-gh-init/
│  ├─ bodies/                    # rendered issue bodies for charlie53
│  └─ logs/
├─ diag.ps1, diag2.ps1, gh-diag.ps1
├─ gh-mock-experiment.ps1, gh-mock-experiment2.ps1
└─ ghexp/
```

When the next run (`gap-miner-v2-kilo38`) was about to start, these `charlie53` artifacts were still present. A fresh run composes its **own** driver, so it would not have loaded the stale one automatically — but a human (or a less-careful agent) could easily have mistaken `gapminer-gh-init-driver.ps1` for reusable and pointed it at the wrong repo, with the wrong node mapping. The risk is silent mis-targeting of a GitHub-mutating run.

---

## Root cause

No convention governed where run scratch lived. Drivers, bodies, logs, and diagnostics were written directly under a flat `/tmp/kilo/` with no per-repo namespacing, so:

1. **Cross-run collision** — artifacts from repo A sat beside artifacts from repo B with nothing distinguishing them but filenames the agent chose ad hoc.
2. **No clean cleanup target** — removing one run's state required identifying each file individually; `rm -rf` of the whole dir would nuke other runs.
3. **Reuse risk** — a stale driver on disk looks reusable and hardcodes a specific repo + node set.

---

## The fix — per-repo scratch namespace

All per-run temp state lives under **one directory per repo**, rooted at `/tmp/kilo/`:

```
/tmp/kilo/<repo-slug>/
  ├─ driver.<ext>   # composed orchestration script for this run
  ├─ bodies/        # rendered file bodies passed to tools (e.g. issue -BodyFile)
  ├─ logs/          # trace / run logs
  └─ diag/          # throwaway diagnostic / experiment scripts
```

- **Root is `/tmp/kilo/`** — the bash tool's pre-approved external-work directory. Scratch goes **under** it (not directly under `/tmp/<slug>/`), so there is no external-dir approval prompt and no collision with the OS `/tmp`.
- **Namespace by repo slug** — e.g. `/tmp/kilo/gap-miner-v2-kilo38/`. One dir per repo isolates state; cleanup is a single `rm -rf /tmp/kilo/<repo-slug>`.
- **`diag/` is nested inside the slug dir**, not a sibling top-level namespace — so one repo = one cleanup target, while still keeping diagnostics separated from run output within that root.
- **Create on demand** (`mkdir -p` / `New-Item -ItemType Directory -Force`). Never assume a previous run's scratch belongs to the current one; before reusing anything under `/tmp/kilo/`, confirm the slug matches the current repo.
- **Durable artifacts are not scratch.** Trace logs worth keeping, fix write-ups, and decision records go under `docs/plans/`, not `/tmp/kilo/`.

---

## Concrete patches (applied in this repo)

### Patch A — `.agents/rules/tools.md` (repo-wide rule)

Appended a new top-level **"Scratch Workspaces (per-run temp state)"** section after the "Exa Search (MCP)" section. It states the `/tmp/kilo/<repo-slug>/` root, the standard layout, create-on-demand, the slug-match-before-reuse check, and the "durable artifacts go under `docs/plans/`" carve-out. This is the **repo-wide** convention — it applies to every skill and agent, not only `gh-issue-tracking-init`.

### Patch B — `.agents/skills/gh-issue-tracking-init/SKILL.md` (skill-specific layout)

Inserted a **"Scratch workspace — isolate the run under `/tmp/kilo/<repo-slug>/`"** subsection at the top of the "Delegation performance (batching)" section (right before the "compose a single PowerShell orchestration script" guidance it relates to). It references the repo convention, gives the gh-init-specific files (`driver.ps1`, `bodies/`, `logs/`, `diag/`), and cites the `charlie53` near-reuse as the cautionary example.

---

## Why two levels

- **Repo-wide (`tools.md`)** — the principle ("namespace temp state by repo under `/tmp/kilo/`") is not specific to this skill; any composed run or subagent that writes scratch should follow it. Putting it only in the skill would leave every other skill free to repeat the flat-`/tmp/kilo/` mistake.
- **Skill-specific (`SKILL.md`)** — the concrete file layout a `gh-init` driver must use (`driver.ps1` / `bodies/` / `logs/` / `diag/`), next to the driver-composition guidance that produces those files.

The skill section links up to the repo rule rather than restating the rationale, so there is one source of truth for the *why*.

---

## Upstream change checklist

| File | Action | Finding |
|------|--------|---------|
| `.agents/rules/tools.md` | Add "Scratch Workspaces (per-run temp state)" section (repo-wide rule + layout) | S1, S2 |
| `.agents/skills/gh-issue-tracking-init/SKILL.md` — "Delegation performance (batching)" | Add "Scratch workspace" subsection with the gh-init layout + `charlie53` caution | S1 |
| `.agents/skills/gh-issue-tracking-init/README.md` | No change (human overview; scratch layout is a driver-author concern, not user-facing) | — |
| `scripts/` | No change (where scratch lives is a driver-concern, not an operation-script contract) | — |

---

## Propagation note (this repo is the upstream template)

Per the project's *Template-repo content strategy* (`.agents/memory.md`), this repository is the **upstream template**: both `.agents/rules/tools.md` (repo-root rule) and `.agents/skills/gh-issue-tracking-init/` are Class-1 reusable infrastructure that travel with every clone. Applying the fix here propagates it to all downstream clones automatically — no separate "hand off" is required beyond committing Patches A and B.

For a downstream clone that already has stale flat-`/tmp/kilo/` contents from a prior run, the one-time cleanup is:

```bash
rm -rf /tmp/kilo/*   # then let the next run recreate /tmp/kilo/<its-own-slug>/
```

---

## Verification

- `grep` confirms the **"Scratch Workspaces"** section is present in `.agents/rules/tools.md` and the **"Scratch workspace"** subsection in `SKILL.md`.
- Code fences balanced after the inserts (`tools.md` 2 fences = 1 block; `SKILL.md` 10 fences = 5 blocks).
- `/tmp/kilo/` cleaned of the stale `charlie53` artifacts (driver, `bodies/`, `logs/`, `diag*`/`gh-mock*` scripts); root retained as the sanctioned scratch location, now empty.
- No script changes → Pester suite unaffected (46/46 green from the prior change still holds).

---

## Companion doc

- [`gh-issue-tracking-plan-source-resolution.md`](./gh-issue-tracking-plan-source-resolution.md) — the sibling upstream fix (non-interactive plan-source resolution) addressed in the same session.

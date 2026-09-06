# Upstream Fix — `gh-issue-tracking-init` must resolve the plan source non-interactively

**Origin:** `intel-agency/gap-miner-v2-kilo38` · **Date:** 2026-07-18
**Target:** the `gh-issue-tracking-init` skill (`.agents/skills/gh-issue-tracking-init/`)
**Type:** Skill contract defect (interactive prompt in a non-interactive skill)
**Status:** Fix applied in this repo (which is the upstream template — see propagation note below)

> This skill is designed for **non-interactive** execution: given a repo and a
> `plan_docs/` directory, it must run to completion without stopping to ask the user
> questions. When the agent stopped to ask *"which plan doc should I use?"* between
> `development-plan.md` and the `Strategic Feasibility….md` reference doc, that was a
> **defect**, not correct caution. The choice was deterministic from filename + role.

---

## TL;DR

| ID | Severity | Type | One-line fix |
|----|----------|------|--------------|
| P1 | **High** | Skill contract defect | Replace *"confirm the selection (or merge) with the user"* in `SKILL.md` Inputs with a **non-interactive plan-doc set resolution** that picks the primary development plan by filename role and folds the rest into the Plan body as supporting context. |
| P2 | High | Skill contract defect | Replace the orchestration preface *"ask before doing anything"* with the same non-interactive resolver; the **only** legitimate hard stop is an empty/missing `plan_docs/` with no plan supplied. |
| P3 | Medium | Companion doc | Mirror the new behavior in `README.md`'s "Both inputs are optional" note so the human-facing overview stops promising a default that prompts. |

---

## Symptom (the incident)

Invoking `gh-issue-tracking-init` with no arguments against `intel-agency/gap-miner-v2-kilo38`, where `plan_docs/` contains:

- `plan_docs/development-plan.md` — *"Gap Mining Platform — Autonomous Agent Development Plan v1.0"*, an executable task plan (Phases 0–6, Tasks T-0.1…T-6.3, acceptance criteria, dependency map).
- `plan_docs/Strategic Feasibility and Execution Plan for AI-Accelerated Micro-SaaS Ecosystems.md` — prose business/marketing analysis, cited by the dev plan as **"Source References … strategic context"** and again in §1 as *"Read-Only Background"*.

The agent (correctly following the then-current `SKILL.md`) **stopped and asked the user** which doc to use, instead of proceeding. The user dismissed the prompt and reported: *"this skill is for non-interactive execution, you should not stop and ask for approval — if you need to then it's a defect."*

---

## Root cause

The skill treated **every** `plan_docs/*.md` file as an equally-weighted candidate *plan* requiring human disambiguation, and offered to "merge them in filename order". Two flaws:

1. **No role classification.** The skill did not distinguish a *primary development plan* (executable task structure → drives the issue tree) from *supporting/reference docs* (architecture guide, strategic context → context only). It lumped them together as "plan source".
2. **Interactive fallback by default.** The resolution contract was *"confirm the selection … with the user before proceeding"* / *"ask before doing anything"* — i.e. the default path was to prompt, when the default path must be to **resolve deterministically and continue**.

In reality, plan documents arrive as a **set** that together describes the application, and each member has a recognizable role encoded in its filename:

- **Primary development plan** — `development-plan`, `app-plan`, `application implementation specification`, …
- **Architecture guide** — `architecture-guide`, `architecture-plan`, …
- **Reference / background** — `strategic …`, `feasibility …`, `vision …`, … (cited as background by the primary plan)

Only the **primary plan** becomes plan→epic→story→task nodes. The others are linked from the Plan issue body as supporting context. Merging a prose reference doc into the node tree produces ill-fitting epic/story nodes (the very failure mode the prior "merge" option risked).

---

## The fix — plan-doc set auto-resolution (never prompt to choose)

Classify each `plan_docs/**/*.md` by **filename slug** (lower-cased, separators normalized) into one of three roles. Use the **primary plan** as the node source; fold the rest into the Plan issue body.

| Role | Filename slugs (match any, word-boundary, case-insensitive) | Used for |
|------|-------------------------------------------------------------|----------|
| **Primary plan** → issue tree | `development-plan`, `development plan`, `app-plan`, `application-plan`, `implementation`, `implementation-spec`, `implementation plan`, `specification` | Parse into plan→epic→story→task nodes. |
| **Architecture** → context | `architecture`, `architecture-guide`, `architecture-plan`, `architecture overview` | Reference in the Plan body + relevant epic bodies. |
| **Reference / background** → context | everything else (`strategic`, `feasibility`, `vision`, `context`, `research`, …) | Reference in the Plan body only. |

> **Bare `plan` is deliberately NOT a primary slug** — words like "execution plan" or "strategic plan" contain "plan" but are not development plans.

**Resolution rules (deterministic; log the choice; never block except rule 5):**

1. **Exactly one primary plan** → use it. Fold architecture + reference docs into the Plan body under a *"Supporting Documents"* section (linked, not merged).
2. **No primary plan, exactly one doc total** → use that doc as the primary plan.
3. **No primary plan, multiple docs** → pick the doc whose body has the strongest task structure (count headings matching `^#+\s*(T-?\d+[-.]?\d*|Task\s|Phase\s|Story\s|Epic\s)`); tie-break by filename order.
4. **Multiple primary plans** → use the first in filename order and log a one-line rationale. *(Two development plans in one `plan_docs/` is genuine ambiguity, but it still resolves deterministically — never prompt. If the user intended to merge split-plan parts, they pass an explicit plan source.)*
5. **Zero docs** (`plan_docs/` missing or empty) → **hard stop**: require the user to supply a plan source explicitly. *This is the only legitimate prompt.*

**Never** create epic/story/task nodes from architecture or reference docs. **Never** "merge" supporting docs into the node tree.

---

## Concrete patches (applied in this repo)

### Patch A — `SKILL.md`, *Inputs → Plan source* bullet

Replaced the *"confirm the selection (or merge) … with the user"* default with the plan-doc set table + the five deterministic resolution rules (rules 1–5 above), ending with: *"The only case that requires the user to supply a plan source explicitly is when `plan_docs/` is missing or empty."*

### Patch B — `SKILL.md`, *Orchestration → Resolve inputs first* preface

Replaced *"if either can't be resolved and the user hasn't supplied it, ask before doing anything"* with: *"…resolve it non-interactively from `plan_docs/` per the plan-doc set convention — classify by filename role, use the primary plan as the node source, and fold the rest into the Plan body as supporting context. The only hard stop is an empty/missing `plan_docs/` with no plan supplied; everything else resolves automatically. **Do not prompt the user to choose between plan docs.**"*

### Patch C — `README.md`, the *"Both inputs are optional"* note

Replaced *"the plan source defaults to every document under `plan_docs/`"* with: *"…the plan source is resolved **non-interactively** from `plan_docs/` — the primary development plan (e.g. `development-plan.md`) drives the issue tree, while architecture/reference docs (e.g. `architecture-guide`, strategic context) are folded into the Plan issue body as supporting context."*

---

## Upstream change checklist

| File | Action | Finding |
|------|--------|---------|
| `SKILL.md` — *Inputs → Plan source* (~lines 36–41) | Replace "confirm the selection (or merge)" default with the plan-doc set table + resolution rules 1–5 | P1 |
| `SKILL.md` — *Orchestration → Resolve inputs first* (~lines 70–73) | Replace "ask before doing anything" with non-interactive resolver; keep empty-`plan_docs/` as the sole hard stop | P2 |
| `README.md` — *"Both inputs are optional"* note (~lines 18–21) | State the plan source is resolved non-interactively (primary plan → tree; arch/reference → Plan body) | P3 |
| `references/gh-issue-tracking-plan.md` | No change (design rationale; does not describe the multi-doc case) | — |
| `scripts/` | No change (plan-source classification is agent parse-time work, not a GitHub op) | — |

---

## Why no new script

Plan-source resolution is a **parsing/classification** step the agent performs at compose-time (it reads the docs with `glob`/`Read`, classifies by filename role, and hardcodes the resulting node mapping into the PowerShell driver's `$nodes` array). That matches the skill's architecture split: **`SKILL.md` is the contract** (what to build), **`scripts/` are mechanical GitHub operations** (create issue / link / set field). The filename-role classification is not a GitHub op, so it stays in the contract as guidance — not a new script.

---

## Propagation note (this repo is the upstream template)

Per the project's *Template-repo content strategy* (`.agents/memory.md`), this repository is the **upstream template**: the `gh-issue-tracking-init/` directory is Class-1 reusable infrastructure that travels with every clone. Applying the fix here propagates it to all downstream clones automatically — no separate "hand off" is required beyond committing these three edits. Downstream clones only need to re-run the skill to pick up the corrected contract.

---

## Verification

- `grep` confirms the phrases *"confirm the selection"*, *"merge them in filename order"*, and *"ask before doing anything"* are gone from `SKILL.md`, and *"defaults to every document under `plan_docs/`"* is gone from `README.md`.
- The Pester suite (`scripts/tests/GhIssueTracking.Tests.ps1`) is unchanged — it exercises the operation scripts and `labels.json`, not the `SKILL.md`/`README.md` prose — and remains green.
- Replay of the original incident against this repo's `plan_docs/`: the resolver classifies `development-plan.md` → **Primary plan** (slug `development-plan`), and `Strategic Feasibility….md` → **Reference/background** (contains no primary slug; bare `plan` excluded by design), then proceeds without prompting — matching the human-obvious answer.

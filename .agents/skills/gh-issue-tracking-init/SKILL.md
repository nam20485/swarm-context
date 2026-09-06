---
name: gh-issue-tracking-init
description: Use when initializing (or re-syncing) a GitHub issue-based planning hierarchy in a repo — a plan → epic → story → task tree of linked sub-issues plus a Projects v2 board, milestones, and labels. Composes the idempotent PowerShell operation scripts in this skill's own scripts/ directory (self-contained) to build the structure from a plan document and the issue templates. Trigger when the user asks to "set up GH issue tracking", "create the plan/issue hierarchy", "scaffold epics/stories/tasks as issues", or names a target repo ($ghrepo) to initialize.
---

# gh-issue-tracking-init

Initialize the GitHub issue-tracking hierarchy — defined in the design plan
at [`references/gh-issue-tracking-plan.md`](./references/gh-issue-tracking-plan.md)
— for a target repository. The heavy lifting is done by idempotent PowerShell
operation scripts in this skill's own
[`scripts/`](./scripts/) directory (see its
[`README.md`](./scripts/README.md)); this skill decides
**what** to create from the plan and composes those scripts to do it.

This skill is **fully self-contained**: its `scripts/` directory vendors the
small set of general-purpose GitHub CLI helpers it depends on
(`common-auth.ps1`, `import-labels.ps1`, `create-milestones.ps1` — also kept at
the repository root as generic utilities), its issue body templates live in
[`assets/templates/`](./assets/templates/), and the canonical label taxonomy
ships as [`assets/labels.json`](./assets/labels.json). The skill has no
dependency on anything outside its own directory — copy
`gh-issue-tracking-init/` into another repo and it works unmodified.

## Inputs

Both inputs have defaults and may be omitted — the skill then runs against the repo
it is invoked from.

- `$ghrepo` — target repository as `owner/repo` (or a URL you normalize to that).
  **Default when omitted:** the repository the skill is running from — the GitHub
  repo of the current working directory, resolved with
  `gh repo view --json nameWithOwner -q .nameWithOwner` (equivalently, the `origin`
  remote of the enclosing git repo). Use this default unless the user names a
  different repo.
- **Plan source** — a description of the epics/stories/tasks (a filled plan doc, or
  the user's description) that you map onto the four levels and the numbering scheme.
  **Default when omitted:** resolve `plan_docs/**/*.md` non-interactively using
  filename role classification (match any slug, word-boundary, case-insensitive):

  - **Primary plan** → issue tree. Slugs: `development-plan`, `development plan`,
    `app-plan`, `application-plan`, `implementation`, `implementation-spec`,
    `implementation plan`, `specification`. Parse into plan→epic→story→task nodes.
  - **Architecture** → context. Slugs: `architecture`, `architecture-guide`,
    `architecture-plan`, `architecture overview`. Reference in the Plan body and
    relevant epic bodies.
  - **Reference / background** → context. Everything else (`strategic`,
    `feasibility`, `vision`, `context`, `research`, …). Reference in the Plan body
    only.

  > Bare `plan` is NOT a primary slug — words like "execution plan" or "strategic plan" contain "plan" but are not development plans.

  Resolution rules (deterministic; log the choice; never block except rule 5):
  1. Exactly one primary plan → use it. Fold architecture + reference docs into the Plan body as supporting context.
  2. No primary plan, one doc total → use that doc as the primary plan.
  3. No primary plan, multiple docs → pick the doc with strongest task structure (count headings matching `^#+\s*(T-?\d+[-.]?\d*|Task\s|Phase\s|Story\s|Epic\s)`); tie-break by filename order.
  4. Multiple primary plans → use the first in filename order; log rationale (never prompt).
  5. Zero docs (`plan_docs/` missing or empty) → hard stop: require the user to supply a plan source explicitly.

  The only case that prompts is an empty/missing `plan_docs/` with no plan supplied.

  ## Mapping the plan onto the hierarchy

Plan docs rarely use the words "epic"/"story"/"task" verbatim — they organize work
under their own top-level groupings. Mapping those groupings onto the four levels is
the single most load-bearing decision in the run; apply it deliberately:

- **Whole plan → Plan** (one issue).
- **The plan's top-level work groups → Epics.** These are frequently titled
  **"Phases"** (Phase 0, Phase 1, …), but the same role is played by "Sprints",
  "Stages", "Groups", "Pillars", or numbered milestone sections. **A plan whose top
  layer is "Phases" MUST be treated as: each Phase = one Epic** — this is mandatory,
  not a guess.
- **The plan's leaf work items → Stories.** These are the atomic, independently-
  completable units the plan numbers as tasks (e.g. `T-x.y`, "Task 3.1"). Each
  becomes one Story.
- **Introduce Tasks (the 4th level) only when the plan itself nests a sub-tier
  beneath those leaf items.** A plan structured as Group → Item has no task level;
  its Stories are leaves — that is correct, not a gap.

> **Terminology collision — read carefully.** A plan's **"Phase"** (a top-level work
> group → becomes an Epic) is **NOT** this skill's optional **`Phase` Project field**
> (a cross-cutting single-select board field; see *Conventions*). Same word, different
> meaning. Do **not** create the Phase field just because the plan says "phase" — the
> plan's phases have already become Epics, and adding the field would duplicate that.
>
> **Plan-task id traceability.** When the plan keys its dependency / parallel-execution
> graph by an id (e.g. a *Parallel Execution Map* referencing `T-x.y`), surface that id
> on the corresponding issue so the plan↔issue mapping is self-documenting — e.g. a
> parenthetical suffix in the title (`Story 2.3: Repository Layer (T-1.3)`).

## Prerequisites

- `pwsh` 7+ and `gh` authenticated with the `project` scope (`$GITHUB_TOKEN` is honored).
- Run everything from the repository root. Preview with `-DryRun` before applying.

## Conventions (must follow)

- **Sub-issues only** for hierarchy (plan→epic→story→task). Never use issue-linked
  task lists for parent/child. Plain checklists inside a body are fine for
  acceptance criteria / sub-steps only.
- **Numbered titles:** `Plan: <Name>`, `Epic <N>: <Name>`, `Story <N>.<M>: <Name>`,
  `Task <N>.<M>.<K>: <Name>`. Keep numbering stable across re-runs.
- **Child-issue list identifiers (mandatory).** When rendering a parent-issue body
  (Plan → epics, Epic → stories, Story → tasks), **every** entry in **any** list
  that enumerates child issues must carry its numeric identifier verbatim:
  `Epic <N>:`, `Story <N>.<M>:`, or `Task <N>.<M>.<K>:`. Plain-text bullets without
  identifiers are **never acceptable** in child-issue lists — this applies to the
  Plan body's *Implementation Plan* section (epics + their stories), the Epic body's
  *Epic Stories* and *Implementation Plan* sections (stories + their tasks), and the
  Story body's *Plan* section (tasks). Acceptance-criteria, validation, and plain
  step checklists *within a single issue* are exempt — those describe steps, not
  child issues. The templates carry `<!-- REQUIRED ... -->` reminders in each such
  section; honor them.
- **Level labels:** `plan` / `epic` / `story` / `task`; plus `P0..P3`, `area/*`.
  Workflow state lives in the Project **Status** field, not labels.
- **Milestones** = conceptual work groups (e.g. `POC`, `MVP`, `UI`, `Server`),
  assigned to the epic **and all its descendants**.
- **Phases** are optional; only create the Phase field/values if the plan uses them.
- Bodies come from the templates in
  [`assets/templates/`](./assets/templates/)
  (`application-plan.md`, `epic.md`, `story.md`, `task.md`) — fill placeholders, then
  pass the result to `ensure-issue.ps1` via `-BodyFile`.

## Body composition specification

The templates in `assets/templates/` are skeletons — their placeholders must be
filled with **plan-derived content**, not agent-composed boilerplate. The rules
below govern what lands where. They are enforced at DryRun time (see the filler
detector in *DryRun must assert completeness* below). The single root cause of
the prior content-fidelity defects was that the skill left body composition to
inference, and inference defaulted to filler; this section makes the contract
explicit.

### Plan-content transfer manifest

Each row declares where a class of plan content **must** land, and at what
fidelity. When the plan **does not** contain content for a row, **omit** the
corresponding issue section entirely — do not fabricate placeholder content.

| Plan element | Target issue | Fidelity |
|---|---|---|
| Per-task inline code/config snippet (a `Reference:` block, or equivalent) | Story `Plan → Implementation approach → Reference (from plan T-x.y)` | **Verbatim** in a fenced code block with matching language tag |
| Per-task agent note (e.g. ⚠️ warning, "verify before committing") | Story `Implementation Notes` | **Verbatim** |
| Per-task out-of-scope items | Story `Scope → Out of Scope` | **Omit** the subsection if the task has none specific |
| Cross-cutting mandatory rules / operating principles | Plan body `Development Standards → Mandatory rules` | **Verbatim** (one canonical copy) |
| Naming & code conventions | Plan body `Development Standards → Naming & code conventions` | **Verbatim** |
| Definition of Done | Plan body `Development Standards → Definition of Done` | **Verbatim** |
| Handoff checklist / escalation protocol | Plan body `Development Standards` (last two sub-sections) | **Verbatim** |
| Exact package-version table | Plan body `Exact package versions` | **Verbatim table** — not summarized into prose |
| Repository file tree | Plan body `Repository layout` | **Verbatim tree** — not summarized into a 3-line summary |
| Risk-register rows | Epic `Risk Mitigation Strategies` (relevant rows only) + Plan body full table | Split: each epic gets only the rows whose mitigation references a task within it |
| Prompt-text catalog (if the plan includes one) | The stories whose `Plan` section implements the corresponding prompt | **Verbatim** inside the story's `Reference` fenced block |
| Parallel-execution map / task groups | Plan body (optional summary) | Summarized; blocked-by edges already encode the dependencies structurally |
| Per-epic technology subset | Epic `Brief Technology Stack` | Only rows applicable to that epic; remove the rest |

### Filler prohibition

No two sibling issues (stories under the same epic, or epics under the same
plan) may share a body section whose text is **byte-identical** unless that
section is genuinely common cross-cutting content that has been placed
canonically on the Plan body. Concretely:

- A story's `Plan`, `Implementation Notes`, `Validation Commands`, `Out of Scope`,
  and `Test Strategy` sections must differ in substance from the same sections
  in any sibling story. "Implement per the AC…" / "Add tests…" / "dotnet build
  exit 0" / "CancellationToken / Never hardcode secrets" — these are filler
  when they repeat across stories.
- An epic's `Brief Technology Stack` and `Risk Mitigation Strategies` must
  differ across epics. A 5-line stack block or a 2-row risk table that
  appears in every epic is filler (and, in the case of cross-epic stack
  bleed like "AI/Runtime: …" on a non-AI epic, actively wrong).

When a section has nothing task- or epic-specific to say, **omit the section
entirely** rather than paste boilerplate. The DryRun filler detector (below)
makes this load-bearing: a section body byte-identical across ≥ 3 sibling
issues throws at preview time.

### Canonical cross-cutting content

Cross-cutting rules (mandatory rules / operating principles, naming
conventions, DoD, handoff checklist, escalation protocol, exact versions,
repository layout) live **once** on the Plan body's `Development Standards`,
`Exact package versions`, and `Repository layout` sections. They are **not**
copied into individual story or epic bodies. If a story needs to reference
them, it links to the Plan issue by number (`Part of #<plan-issue>`) — it does
not re-paste the rules.

## Orchestration steps

Work top-down. Always do a `-DryRun` pass first, show the plan, then apply.
All scripts below live in this skill's `scripts/` directory.

**Resolve inputs first.** If `$ghrepo` is not given, derive it from the current
repo (see [Inputs](#inputs)). If no plan source is named, resolve it non-interactively
from `plan_docs/` per the plan-doc set convention above — classify by filename role,
use the primary plan as the node source, and fold the rest into the Plan body as
supporting context. The only hard stop is an empty/missing `plan_docs/` with no plan
supplied; everything else resolves automatically. **Do not prompt the user to choose
between plan docs.**

**Initialize the forensic logfile first.** At the very top of the composed driver
script — before any GitHub call — initialize the per-run logfile so every subsequent
operation (every `Invoke-Gh`, every `Write-Step`/`Write-Ok`/`Write-Skip`/`Write-DryRun`,
across every dot-sourced op script) is mirrored into it for post-execution forensics:

```pwsh
. (Join-Path $Skill 'common.ps1')
$slug = ($ghrepo -split '/')[-1]   # e.g. 'gap-miner-v2-delta12'
$logPath = Initialize-LogFile -RepoSlug $slug -RepoRoot (Get-Location) -Repo $ghrepo
Write-Step "Logging to: $logPath"
```

`Initialize-LogFile` writes a header block recording the repository identity, the
absolute working-copy path, the checked-out git rev + ref, the script directory, and
the OS/PowerShell version. The path is carried in `$env:GHIT_LOG_FILE`, so every op
script (each with its own `$script:` scope) writes to the same file without needing
the path passed in. The file lands at `<repo-root>/gh-init-<slug>-<UTC-timestamp>.log`
and is covered by `.gitignore` (`gh-init-*.log`).

1. **Parse the plan** into a tree of nodes (plan, epics, stories, tasks) with the
   numbered titles above, plus per-node labels, milestone, phase, priority, estimate,
   and any blocking dependencies.

   **Canonical node schema** (assert presence before rendering — an omitted field
   produces empty titles/milestones silently otherwise):
   - `Level` (`plan`/`epic`/`story`/`task`)
   - `Title` (the full numbered title, e.g. `Story 1.1: Bootstrap`) **or** the parts to
     build it (`N`/`M`/`K`, `Name`)
   - `Labels`, `Milestone`, `Priority`, `Phase` (if used)
   - `BodyFile` (after rendering), `Prereqs` (array of sibling keys, story/task level)
2. **Labels:** `ensure-labels.ps1 -Repo $ghrepo`.
3. **Milestones:** for each conceptual group, `create-milestones.ps1 -Repo $ghrepo -Titles <name> -SkipExisting`.
4. **Project + fields:** `ensure-project.ps1 -Owner <owner> -Repo $ghrepo [-Phases <p1,p2>]`.
   Capture the **project number** from stdout (`$Proj = & ensure-project.ps1 ...`); in
   `-DryRun` it is `$null` (the project is not created, so nothing is emitted).
5. **Create issues** (top-down) with `ensure-issue.ps1`, filling the matching template
   into a temp file and passing `-BodyFile`. Capture each printed issue **number**:
   - plan → epics → stories → tasks; apply the level label and (for epics + descendants) the milestone.
6. **Link sub-issues** with `link-sub-issue.ps1 -ParentNumber <parent> -ChildNumber <child>`
   for every parent/child edge.
7. **Set board fields** with `set-project-fields.ps1` for each issue: `-Level`,
   `-Priority`, `-Phase` (if used), `-Estimate`, `-Status` (default `Todo`).
8. **Dependencies:** for each "blocked by" edge, `set-dependency.ps1 -IssueNumber <blocked> -BlockedByNumber <blocker>`.
9. **Views:** `ensure-project.ps1` prints the four views to add once in the Project UI
   (not automatable). Relay that to the user.
10. **Signal completion:** on a successful **apply** run (never in `-DryRun`, never after a
    partial/failed run), apply the `gh-issue-tracking:init-success` label to the **Plan
    issue** (the single plan-level node created in step 5). This label is the orchestration
    hand-off signal — a downstream orchestrator matches it to learn the hierarchy is
    initialized and ready. The label was ensured by step 2, so apply it directly:
    ```pwsh
    # $planNumber = the Plan issue number captured in step 5; $ghrepo = target repo.
    # Guard on success: only the final action of a fully-applied (non-DryRun) run.
    & gh issue edit $planNumber --repo $ghrepo --add-label 'gh-issue-tracking:init-success'
    ```
    A Plan issue is required: if no plan-level node was created (no apply happened, or the
    run was `-DryRun`), skip this step. If the label apply fails, log a warning but do not
    fail the run — the hierarchy itself is already complete.

## Delegation performance (batching)

### Scratch workspace — isolate the run under `/tmp/kilo/<repo-slug>/`

A composed `gh-issue-tracking-init` run writes several artifacts: a PowerShell driver, rendered issue bodies, trace logs, and diagnostic scripts. Put them all under the per-repo scratch namespace from [`.agents/rules/tools.md`](../../rules/tools.md) — `/tmp/kilo/<repo-slug>/` — **not** loose in a flat `/tmp/kilo/`:

```text
/tmp/kilo/<repo-slug>/
  ├─ driver.ps1   # the composed orchestration script (this section's output)
  ├─ bodies/      # rendered issue bodies, passed to ensure-issue.ps1 -BodyFile
  └─ diag/        # throwaway diagnostic / experiment scripts
```

The **canonical forensic run log** is NOT here — `Initialize-LogFile` writes it to
`<repo-root>/gh-init-<slug>-<UTC-timestamp>.log` (see *Initialize the forensic logfile
first* above), where it survives for post-execution forensics. Keep scratch-workspace
`diag/` scripts for one-off experiments only.

This is repo-wide hygiene, not optional: a prior forensic run (`gap-miner-v2-charlie53`) left a stale, repo-hardcoded `gapminer-gh-init-driver.ps1` loose in `/tmp/kilo/`, which a later run could have mistaken for reusable and pointed at the wrong repo. **Create on demand** (`mkdir -p` / `New-Item -ItemType Directory -Force`), and before reusing anything under `/tmp/kilo/`, confirm the slug matches the current repo.

### Compose a single orchestration script (never one op per LLM turn)

When composing these scripts, do **not** invoke each op script as its own LLM turn
(one script per reasoning step). That pattern has been **measured at ~77 minutes** for
roughly the first 40% of a 30-issue hierarchy — the per-turn overhead dominates the
actual REST calls.

Instead, **compose a single PowerShell orchestration script** that builds an issue map
once, then loops through the phases in dependency order:

```pwsh
# build the issue map (title -> number) as ensure-issue.ps1 returns each number,
# then drive the remaining ops in tight loops with a small sleep between
# REST-mutating calls to avoid GitHub's secondary rate limits.
$map = @{}
foreach ($n in $nodes) {
    $map[$n.title] = & "$Skill/ensure-issue.ps1" -Repo $ghrepo -Title $n.title -BodyFile $n.bodyFile -Labels $n.labels -Milestone $n.milestone
    Start-Sleep -Milliseconds 500
}
foreach ($e in $edges) { & "$Skill/link-sub-issue.ps1"   -Repo $ghrepo -ParentNumber $map[$e.parent] -ChildNumber $map[$e.child]; Start-Sleep -Milliseconds 500 }
foreach ($n in $nodes) { $ht = $n.fields; & "$Skill/set-project-fields.ps1" @ht; Start-Sleep -Milliseconds 500 }
foreach ($d in $deps)  { & "$Skill/set-dependency.ps1"  -Repo $ghrepo -IssueNumber $map[$d.blocked] -BlockedByNumber $map[$d.blocker]; Start-Sleep -Milliseconds 500 }
```

### `set-project-fields.ps1` must use hashtable splatting

`set-project-fields.ps1` binds parameters **by name**. When you compose calls, use
**hashtable splatting** (`@ht`), never array splatting (`@a` of a `string[]`):

```pwsh
$ht = @{ Owner=$Owner; ProjectNumber=$Proj; Repo=$ghrepo; IssueNumber=$n.number; Level='story'; Status='Todo'; Priority='P1'; Phase='X' }
& "$Skill/set-project-fields.ps1" @ht
```

**Important:** array splatting (`@a` of a `string[]`) is **positional** and will misbind
parameter names — this was the one call-site bug observed in the forensic run. Always
splat a hashtable for this script.

### Avoid integer-keyed lookup dictionaries in the driver

PowerShell integer-keyed `[ordered]@{}` / `@{}` indexing is **unreliable for some keys**
(silent empty returns; reproduced on PS 7.6 — keys 1–6 resolve while key 7 returns empty
even though `.Keys` and `.Values` confirm it is present). When composing a driver, **do
not** build milestone/phase lookup maps as integer-keyed dictionaries. Prefer, in order:

1. a `switch` function (single source of truth, fails loudly on unknown keys), or
2. a `[string]`-keyed `@{}` accessed via `$map["7"]`.

```pwsh
function Milestone-For {
    param([int]$N)
    switch ($N) {
        1 { 'Gate 1: Foundation' }
        2 { 'Gate 1: Foundation' }
        3 { 'Gate 2: Pipelines' }
        default { throw "Unknown epic number for milestone: $N" }
    }
}
```

### DryRun must assert completeness

Before printing the DryRun preview, assert every node renders a non-empty title and (for
epics/stories) a non-empty milestone. Throw on the first empty value so omissions fail
loudly in preview rather than creating empty-titled issues on apply:

```pwsh
foreach ($n in $nodes) {
    if ([string]::IsNullOrWhiteSpace($n.Title)) { throw "Node missing title: $($n | ConvertTo-Json -Compress -Depth 2)" }
    if ($n.Level -in 'epic','story' -and [string]::IsNullOrWhiteSpace($n.Milestone)) { throw "Node $($n.Title) missing milestone" }
}
```

### DryRun must assert no filler (body duplication across siblings)

After the title/milestone check above, also assert that no `##`/`###` section body is
**byte-identical across ≥ 3 sibling issues** at the same level (stories under one epic,
or epics under one plan). Identical section bodies across siblings is the strongest
filler signal — it means the section was pasted from a template rather than derived from
the plan. See [Body composition specification](#body-composition-specification) above for
the rules this enforces. Run this over the rendered body files in the DryRun pass (before
any `gh` create call):

```pwsh
# $bodies = array of [pscustomobject]@{ Title=...; Level=...; BodyFile=... }
# Group by Level so siblings are only compared to siblings (stories vs. stories, epics vs. epics).
$byLevel = $bodies | Group-Object Level
foreach ($group in $byLevel) {
    $sectionHashes = @{}   # key = "depth|heading|bodyHash" -> @{ Heading = ...; Titles = ... }
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    # Defined once per group: PowerShell resolves $b, $currentHeading, etc. via dynamic
    # scoping at call time, so the script block is independent of where it is defined.
    $saveSection = {
        if ($currentHeading) {
            $bodyText = $currentBody.ToString().Trim()
            if (-not [string]::IsNullOrWhiteSpace($bodyText)) {
                $sha = $hasher.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($bodyText))
                $hash = [System.BitConverter]::ToString($sha).Replace('-','').Substring(0,16)
                $key  = "$currentDepth|$currentHeading|$hash"
                if (-not $sectionHashes.ContainsKey($key)) {
                    $sectionHashes[$key] = [pscustomobject]@{
                        Heading = $currentHeading
                        Titles  = New-Object System.Collections.Generic.List[string]
                    }
                }
                if (-not $sectionHashes[$key].Titles.Contains($b.Title)) {
                    [void]$sectionHashes[$key].Titles.Add($b.Title)
                }
            }
        }
    }
    try {
        foreach ($b in $group.Group) {
            # Filter nulls defensively so .StartsWith() below can't hit a NullReferenceException.
            $lines = Get-Content -LiteralPath $b.BodyFile | Where-Object { $null -ne $_ }
            $inCodeBlock = $false
            $currentHeading = $null
            $currentDepth = 2
            $currentBody = [System.Text.StringBuilder]::new()

            foreach ($line in $lines) {
                if ($line.StartsWith(([string][char]96) * 3)) {
                    $inCodeBlock = -not $inCodeBlock
                }
                if (-not $inCodeBlock -and $line -match '^(#{2,})\s+(.+)$') {
                    . $saveSection
                    $currentDepth = $Matches[1].Length
                    $currentHeading = $Matches[2].Trim()
                    [void]$currentBody.Clear()
                } elseif ($currentHeading) {
                    [void]$currentBody.AppendLine($line)
                }
            }
            . $saveSection
        }
    } finally {
        $hasher.Dispose()
    }
    foreach ($key in $sectionHashes.Keys) {
        $entry = $sectionHashes[$key]
        if ($entry.Titles.Count -ge 3) {
            $heading  = $entry.Heading
            $offenders = ($entry.Titles -join ', ')
            throw ("Filler detected: section '$heading' is byte-identical across " +
                   "$($entry.Titles.Count) $($group.Name) issues: $offenders. " +
                   "Omit the section where it has no sibling-specific content, or place " +
                   "common cross-cutting content canonically on the Plan body.")
        }
    }
}
```

The threshold is ≥ 3 (not 2): two sibling issues legitimately sharing a section (e.g. two
stories that both reference the same config fragment) is allowed; three or more is a
filler pattern. Cross-cutting content that genuinely belongs in every issue must live
**once** on the Plan body — see [Canonical cross-cutting content](#canonical-cross-cutting-content).

### DryRun must assert no secrets in body files

After rendering bodies (and after the filler check above), run
`assert-no-secrets.ps1` over **every** rendered body file before any
`gh issue create` call. Plan-doc `Reference:` snippets reproduced verbatim into
issue bodies can carry credentials (connection strings with passwords, API keys,
bearer tokens). Secrets posted to public GitHub issues are a one-way door —
scraped within seconds, cached by archives even after deletion.

```pwsh
& "$Skill/assert-no-secrets.ps1" -BodyFiles $bodies.BodyFile
```

The script throws on confident detection and **halts the run** — no automatic
redaction. The error message reports file + line + pattern category + the
offending line. To remediate: redact the secret in the plan doc and re-run.

Placeholder allowlist: the scanner recognizes `${VAR}`, `changeme`, `redacted`,
`<YOUR_API_KEY>`, `example.com`, `…` as safe — plan docs that use interpolation
do not false-positive. See `scripts/assert-no-secrets.ps1` for the full pattern
and allowlist inventory.

**Escape hatch:** if the scan false-positives on content the user has verified is
safe, call with `-DryRun` (report-only, no throw) and relay the findings for
manual confirmation before proceeding:

```pwsh
& "$Skill/assert-no-secrets.ps1" -BodyFiles $bodies.BodyFile -DryRun
```

## Idempotency & re-runs

The scripts match existing labels/milestones/fields/issues (by numbered title)/links
and skip or update rather than duplicate. Re-run this skill after editing the plan to
sync additions and changes. Keep titles/numbers stable so matches hold.

## Definition of done

Completion = **closing** a sub-issue (parent progress rolls up automatically). Use the
Project **Status** field for in-flight state. In-issue checklists are informational only.

## Out of scope

The separate issue-implementation skill (current-issue selection / ordering) is
deferred — see the plan's "Out of Scope". **Defects/bugs** are also deferred:
adding a `defect` level would require extending the Project `Level` single-select
*after* field creation, which `gh`/API cannot do (options are only settable at
field creation); shipping it half-working would force a manual UI step on every
re-run, so it is intentionally omitted until that can be fully automated.

## Known limitations

Decide with these in mind up front (not only at script-reference time):

- **Project views are not automatable.** `gh`/API has no supported "create view" operation; `ensure-project.ps1` prints the four views to add once in the Project UI: **By Phase, By Status, By Epic, Current work**.
- **Built-in `Status` options are limited.** `gh` cannot add options to an existing single-select field, so the initial set is `Todo / In Progress / Done`. If your workflow needs `In Review` or `Blocked`, add those once in the UI.
- **GitHub database IDs exceed Int32.** Global issue DB IDs exceed `Int32.MaxValue` (2,147,483,647); `Get-IssueDbId` casts to `[long]`, so `link-sub-issue.ps1` and `set-dependency.ps1` work against modern repos (fixed in this release).

## Validation

Run the Pester suite for the scripts, and the user-run end-to-end smoke test against a
throwaway repo — both documented in
[`scripts/README.md`](./scripts/README.md).

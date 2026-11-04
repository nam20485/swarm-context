# Survey: Implementation options — gh-issue-tracking-init ↔ beads via a `beads.jsonl` intermediate representation

Status: SURVEY (options, pros/cons, recommendations — not yet an implementation plan)
Date: 2026-11-04
Parent plan: [`gh-issue-tracking-init-to-beads.md`](./gh-issue-tracking-init-to-beads.md)
Skill under change: `.agents/skills/gh-issue-tracking-init/`
Evidence base: first-hand `bd` experiments (scratch Dolt DBs under
`/tmp/kilo/swarm-context/bd-scratch*` = v1.0.4 and `bd-scratch134/` = v1.3.4, both
2026-11-04) + beads source/docs research at tag `v1.3.4` and `main` (citations
inline). The installed binary was upgraded 1.0.4 → **1.3.4** (latest release,
published 2026-11-04) after the first draft; every load-bearing fact was
re-verified on 1.3.4 and version differences are tagged per row.

## 1. Goal restated

The parent plan wants the gh-issue-tracking-init output (a Plan → Epic → Story → Task
hierarchy of linked sub-issues, plus Projects v2 board, milestones, labels, blocked-by
dependencies) to be:

1. **Serialized to a file** — capturable, saveable, loadable (an intermediate
   representation, "IL").
2. **Replayable to GitHub** — read the file, (re)generate the GH hierarchy from it.
3. **Importable to / exportable from beads** — the IL already being `beads.jsonl` format
   makes this near-free.
4. **Usable outside the skill** — the sync/import/export functionality must stand alone.
5. Extra-GH objects (projects, labels, milestones) modeled as a **superset** of
   `beads.jsonl` that beads ignores while the skill serializes/deserializes them.

## 2. Ground truth — verified bd behavior (1.0.4 and 1.3.4)

Every claim below was verified first-hand on this machine (against `bd` 1.0.4
and re-verified against installed **1.3.4** unless the row says otherwise) or
source-verified in the upstream repo at a pinned ref (**[v1.3.4]** / **[main]** —
`main` is ahead of the latest release and its extras are **not** in the installed
binary).

| # | Fact | Evidence |
|---|------|----------|
| G1 | `bd export` emits one JSON object per line: `{"_type":"issue","id","title","status","priority","issue_type","owner","created_at","created_by","updated_at","metadata","labels","external_ref","dependencies":[…],"dependency_count","dependent_count","comment_count", …}` | scratch export |
| G2 | **Hierarchy is a dependency edge**, not a field: `{"issue_id":<child>,"depends_on_id":<parent>,"type":"parent-child"}`. Blocking is the same array with `"type":"blocks"`. `bd dep add` at 1.0.4 accepts: `blocks, tracks, related, parent-child, discovered-from, until, caused-by, validates, relates-to, supersedes` (enum verified live); `internal/types/types.go` @v1.0.4 additionally defines `conditional-blocks`, `waits-for`, `duplicates` and more (source-read) | scratch export; `bd dep add --help`; `internal/types/types.go` @v1.0.4 |
| G3 | `--parent` creation mints dotted child ids (`bd-x.1`); `--graph` `parent_key` mints flat ids. Both serialize as the same `parent-child` edge — **the edge is canonical; the dotted id is cosmetic** | scratch export both ways |
| G4 | `bd import <file>` upserts **matched by `id`** (batch); modified title/status on an existing id updates in place, no duplicates. Only `title` is required per line; every export field is honored (`description`, `issue_type`, `priority`, `status`, `labels`, `dependencies`, `metadata`, `external_ref`, …). Unknown **keys** are silently ignored. **1.3.4 adds** structured `--json` output (`created`/`ids`/`updated_issues` with field-level change summary/`stale_skipped_ids`) | scratch import of edited export (both versions) |
| G5 | ⚠️ **Superset-in-one-file is unsafe**: records with an unknown `_type` (e.g. `{"_type":"gh_project","title":"My Board"}`) are **not skipped** — they fall through and import as title-only issues (verified: imported as a `P0` issue "My Board"). `bd` neither chokes nor preserves them; it garbage-imports them. **Still true on 1.3.4** (re-verified live) | scratch import, both versions |
| G6 | `_type:"memory"` lines import as persistent memories — **only in the canonical `{"_type":"memory","key":…,"value":…}` shape** (other shapes are silently counted as 0 memories); `status:"tombstone"` lines are skipped | review-wave import test; `cmd/bd/import.go` @v1.0.4 |
| G7 | `bd create --graph file.json` accepts `{commit_message, nodes[], edges[]}`; node: `key,title,type,description,assignee,assign_after_create,priority,labels,metadata,parent_key,parent_id`; edge: `{from_key|from_id, to_key|to_id, type}` (default `blocks`); prints a **key → minted-id map**. **1.3.4 additionally honors node `status`, `external_ref`, `estimated_minutes`, and arbitrary-JSON `metadata` (live-verified; 1.0.4 accepted only string-map metadata)**; the 1.0.4-era schema still imports unchanged | scratch `--graph` runs, both versions |
| G8 | ⚠️ `bd create --graph` is **not idempotent** — re-running the same plan creates duplicates (verified: 8 → 11 issues; re-verified on 1.3.4, 5 → 8 → 11) | scratch re-runs, both versions |
| G9 | `external_ref` is a native round-tripping field (e.g. `"external_ref":"gh-9"`); `bd github sync` uses the issue **HTML URL** as `external_ref` and `github:<url>:<number>` as `source_system` | scratch export; `internal/github/mapping.go` @v1.0.4 |
| G10 | `bd init` creates `.beads/` (Dolt). **1.0.4:** auto-export after writes to `.beads/issues.jsonl` (throttled 60 s; `export.auto` = true). **1.3.4:** `export.auto` defaults to **false** on a fresh init (verified) — the git-tracked `.beads/issues.jsonl` must now be produced explicitly (`bd export -o`) or enabled via config; import's default source is the `import.path` config key (default `.beads/issues.jsonl`) | scratch inits, both versions; `bd config get export.auto` |
| G11 | `bd github sync` at **1.0.4** maps only: title, body↔description, labels (with `type::/priority::/status::` scoped-label conventions), state open/closed, assignee, priority, timestamps. **No sub-issues, no milestones, no comments, no Projects v2.** Conflict modes: `--prefer-local/--prefer-github/--prefer-newer` (default). Content-hash skips no-op PATCHes; 403/429 retry/backoff; paged at 100. Caution: sync's `--parent` flag ("limit push to this bead and its descendants") hints partial hierarchy awareness — verify before relying on "no sub-issues" absolutely | help + `internal/github/mapping.go`, `client.go`, `internal/tracker/engine.go` @v1.0.4 (source-read) |
| G12 | ⚠️ **Correction after upgrade:** native sub-issue sync is **NOT in v1.3.4**. `internal/github/links.go` (maps beads `parent-child` → GH **sub-issues**, `blocks` → GH `blocked_by`; additive, idempotent) exists only on **`main` ahead of the v1.3.4 tag** (published 2026-11-04, the latest release). Verified by tagged tree listing + grep: v1.3.4's `internal/github/` has no links.go and no sub_issue/blocked_by handling anywhere. Still no Projects v2 / milestone-object sync even on main | upstream repo at refs `v1.3.4` and `main` (via gh api) |
| G13 | `bd query` filter fields do **not** include `external_ref` (still true on 1.3.4). Matching by external_ref must be done client-side (e.g. filter `bd export` output) | `bd query --help`, both versions |
| G14 | Import staleness guard: **1.0.4** upsert is last-writer-wins. **1.3.4 (live-verified)**: a row only rewrites an existing issue when its `updated_at` is strictly newer — older rows are skipped (`stale_skipped_ids`), same-second ties keep local (`tie_kept_local_ids`, labels/comments/dependencies still merge), the guard is enforced inside the upsert too, and `--allow-stale` force-restores. Imports also land in bounded transactions in dependency order (no half-imported blocked-as-ready states) and converge on re-run | scratch import with stale/newer rows on 1.3.4 |
| G15 | Repo has **no Python today** (zero `.py`, no pyproject/requirements/uv.lock); `validation.ps1` gates Pester (coverage ≥85%) + PSScriptAnalyzer + gitleaks + markdownlint — **Python files are invisible to the coverage/test gate** | repo scan |
| G16 | gh CLI has no `sub-issue` subcommand; the skill links sub-issues via `gh api` REST (`POST repos/{o}/{r}/issues/{parent}/sub_issues`) — `bd` on main does the same endpoint natively (links.go; not in v1.3.4, see G12) | skill scripts + upstream links.go at `main` (source-read) |
| G17 | `bd import` **mints ids for id-less lines** (the G5 garbage records landed with fresh ids), and `--json` returns the created-id list — so a pre-bootstrap IL may omit `id` entirely and still import, with the minted ids recoverable from `--json` output (though keyed only by position, not by node key — C2's `--graph` map remains the cleaner bootstrap) | G5 experiments, both versions |
| G18 | `bd create --force` exists for exactly the prefix-mismatch case ("Force creation even if prefix doesn't match database prefix") | `bd create --help` |

## 3. The model-mapping problem (what the IL must translate)

| GH object (skill) | beads counterpart | Gap / decision needed |
|---|---|---|
| Sub-issue edge (parent/child) | dependency edge `type:"parent-child"` (G2) | none — clean 1:1 |
| `blocked_by` dependency | dependency edge `type:"blocks"` (G2) | none — clean 1:1 |
| Issue body (template markdown) | `description` | none (fidelity is full markdown) |
| Labels `plan/epic/story/task` | `labels` (verbatim) **or** `issue_type` | beads `issue_type` only has epic/task/bug/feature/chore/decision; `plan`/`story` need `types.custom` config. Simplest: keep levels as **labels**, map only `epic`→`issue_type:"epic"` |
| `P0..P3` labels | `priority` 0–4 (numeric) | mechanical map; P3→3, P4 unused |
| Project `Status` field (Todo/In Progress/In Review/Blocked/Done) | `status` (open/in_progress/blocked/deferred/closed) | **not 1:1**: `In Review` has no beads status; GH issue state (open/closed) ≠ board Status. Needs an explicit mapping table + an owner-of-truth rule (recommend: GH board is authoritative; beads mirrors) |
| Milestone | — none (G11) | must live in the superset (sidecar + per-issue metadata) |
| Projects v2 board (fields, views) | — none (G11/G12) | superset only |
| Label taxonomy (`assets/labels.json`) | — labels sync as strings, taxonomy definition does not | superset only |
| Issue number (GH identity) | `external_ref` = issue URL (G9) + IL id-map | beads **id** is minted by beads; correlation is external_ref/id-map, never title |

**Consequence:** a pure beads-native format cannot represent milestones, the board, or
the label taxonomy — the superset channel is required, and the status/level mappings
need one explicit decision table wherever the IL is defined.

## 4. Options

### Axis A — IL file format

#### A1. Native `bd export` JSONL + sidecar superset file *(recommended)*

The IL **is** the beads export format: one `*.beads.jsonl` whose lines are exactly
`_type:"issue"` records (with `dependencies` edges, `labels`, `metadata`,
`external_ref`), plus a second file (e.g. `*.gh-meta.json`) holding the superset:
label taxonomy, milestone definitions + assignments, project definition (fields,
Status options, views). Per-issue GH attributes (milestone name, board Status value,
level) ride in the issue line's `metadata` map (string values at 1.0.4, G7).

- **Pros**
  - Requirement 3/“`bd import --file github_issues.jsonl`” (parent plan §6) is
    satisfied **verbatim** — zero translation into beads; `bd export` output is the IL.
  - Round-trip `bd export | bd import` already preserves edges (G2/G4) — verified.
  - Unknown-key tolerance (G4) means beads ignores any future per-issue extras.
  - Sidecar keeps beads from garbage-importing non-issue records (G5 makes one mixed
    file a non-starter — evidence, not conjecture).
- **Cons**
  - Two files to keep atomic (mitigate: write both from one serializer run; the pair
    is produced and consumed together).
  - Beads-owned fields (`created_by`, `owner`, timestamps) are meaningless on the GH
    side; serializer must decide to omit or stub them (import fills defaults).
  - ~~`metadata` string-values-only at 1.0.4~~ — resolved by the 1.3.4 upgrade:
    metadata is arbitrary JSON, preserved verbatim (live-verified, nested object
    round-trip).

#### A2. Single mixed superset JSONL (one file, custom `_type` records)

Rejected by evidence: unknown `_type` records are silently imported as title-only P0
issues (G5 — re-verified live on **1.3.4**, so this is not a version artifact). This
is worse than "beads chokes" — it corrupts the DB quietly. Only viable if beads grew
a skip-list for unknown `_type`s (none found through v1.3.4 or on main).

#### A3. `bd create --graph` plan JSON as the IL

Use the graph-plan format (G7) as the intermediate representation.

- **Pros**: purpose-built batch format; `key` indirection is natural for "GH node not
  yet created"; single call ingests the whole graph and **returns the minted id map**
  (solves GH↔beads correlation in one shot); `commit_message` gives Dolt history a
  meaningful entry.
- **Cons**: it is a **create-only** format — not what `bd export` emits, so export
  direction would need translation anyway (two formats, not one); not idempotent
  (G8) so it cannot be the re-sync format; beads → GH direction has no use for it.

**Verdict:** not the IL — but the **bootstrap ingestion path** (see C2).

#### A4. Custom schema defined in Pydantic (parent plan's stated mechanism)

A bespoke JSON schema (Pydantic models) from which both `beads.jsonl` and GH ops are
generated.

- **Pros**: strongest typing/validation at authoring time; free JSON Schema export;
  familiar to the plan's author.
- **Cons**: it is a *third* format — someone must translate to `bd import`'s accepted
  keys anyway (or the tool re-implements what `--graph`/import already do); the
  runtime (Python+Pydantic) is new to this repo (G15) and invisible to the validation
  gate; schema drift now has three poles (GH API, beads format, Pydantic models).
- **Note:** the *discipline* A4 wants (strong schema, explicit field mapping) is
  achievable in A1 with a Pester-validated round-trip test instead — see D1.

### Axis B — how the skill binds to the IL (and the two directions)

- **B1. Emit-only** (serialize the run's result to the IL afterwards): cheapest, but
  fails parent-plan requirement 2 (read the file → regenerate the hierarchy) — the IL
  would be an output artifact, not a driver.
- **B2. IL-first** *(recommended, GH→IL→GH)*: the skill parses the plan/feature list
  into the IL (nodes + edges + superset), DryRun-validates it, then **drives the
  existing op scripts from the IL** (ensure-issue/link-sub-issue/set-dependency/…),
  and writes the resolved GH numbers back into the IL (`external_ref` + id-map in the
  sidecar) after apply. The IL becomes the capturable, reviewable intermediate the
  parent plan describes; GH ops stay idempotent by numbered title (unchanged skill
  convention). Three binding requirements surfaced in review:
  - **Campaign provenance first**: feature-campaign runs must resolve the live anchor
    (`resolve-plan-root.ps1` → `NextEpicNumber`, `continue-existing` vs
    `new-feature-plan`) **before** IL generation, and record it (anchor plan number,
    mode, next-epic) in the sidecar — a saved IL cannot re-derive repo-wide numbering
    on replay, and the plan body's replace-or-append campaign section is run-scoped.
  - **Bodies are rendered into the IL before validation**: the existing filler
    detector and `assert-no-secrets.ps1` operate on rendered template bodies, so the
    IL's `description` fields carry the fully rendered bodies and DryRun asserts over
    them (this reorders the current validate-then-render flow; state it explicitly in
    the implementation plan).
  - **The `gh-issue-tracking:init-success` label is run-scoped**: never serialized
    into the IL; re-applied only by a successful apply of the current run (a replay
    of an old IL must not re-signal).
- **B3. Dual-mode / reconcile**: B2 plus an "adopt existing" path (read an existing
  IL, diff against live GH, reconcile). The diff must verify IL titles against live
  GH issue numbers via the id-map and fail loudly on mismatch (a title edited since
  last run would otherwise duplicate under `ensure-issue`'s title matching). Natural
  follow-on; not needed for v1.
- **B4. Beads-first adoption (beads → IL → GH)** *(required for parent-plan req 4's
  "export from beads")*: export via `bd export` (G1), merge with the saved sidecar —
  a pure beads export alone **cannot** regenerate the GH hierarchy because
  milestones/board/label-taxonomy have no beads counterpart (§3) — then drive the
  same GH op scripts from the merged IL. Feasible with A1's file pair precisely
  because the sidecar was saved alongside; this is why the pair (not the JSONL alone)
  is the true interchange unit. Recommended as part of v1 scope (it is mostly B2's
  apply path with a different IL source), with the caveat that beads-side edits that
  never passed through an IL (hand-run `bd create`) are only adoptable via B3-style
  reconciliation.

### Axis C — beads ingestion / egress mechanism

#### C1. `bd import` on the IL file (upsert) *(recommended for sync)*

- **Pros**: single command; upsert-by-id verified (G4); stdin-pipeable; `--dry-run`
  and `--dedup` exist; works on the A1 IL unchanged. **On 1.3.4 the staleness guard
  (G14) makes imports safe against out-of-order writes** — stale rows skip instead of
  clobbering, same-second ties keep local, `--allow-stale` force-restores, and
  imports land in bounded dependency-ordered transactions that converge on re-run;
  `--json` reports exactly what was created/updated/skipped.
- **Cons**: needs beads ids to already exist (first run has none — pair with C2);
  on 1.0.4 the upsert was last-writer-wins (ordering was a tool rule, not a guard) —
  moot on the installed 1.3.4.

#### C2. `bd create --graph` for first ingestion *(recommended for bootstrap)*

- **Pros**: one shot mints every id and returns the key→id map (G7) — that map *is*
  the sidecar's id-map; dependency edges created in the same call; no per-issue
  process spawns.
- **Cons**: create-only and non-idempotent (G8) — must be guarded (only run when the
  IL has no beads ids yet; detect existing via export + external_ref filter, G13).

#### C3. Manual `bd` driving (parent plan §7: `bd create --parent`, `bd dep add`)

- **Pros**: no new code at all; fine for a human's one-off.
- **Cons**: N+1 process spawns per issue; no transactionality; no captured id map
  (correlation becomes manual); duplicates the IL's purpose. Fine as **documented
  fallback**, not as the mechanism.

#### C4. Native `bd github sync`

- **Pros** ([main]-only, G12): maintained field-level sync incl. **sub-issues** and
  blocked_by; conflict modes; rate-limit handling — the only option that keeps
  *field edits* (title/body/label/state drift) in sync continuously rather than at
  IL-write time.
- **Cons**: **not in the installed v1.3.4** — `links.go` (the sub-issue/blocked_by
  mapping) is on `main` ahead of the v1.3.4 tag (G12 correction), so this needs a
  future release > v1.3.4 (or a main build); even on main it does **not** cover
  milestones, comments, or Projects v2; its scoped-label conventions (`type::`,
  `priority::`, `status::`) collide with this skill's label taxonomy —
  `github.label_map.*` exists per upstream configuration docs (bd-label → GH-label
  name mapping; whether it suppresses the scoped-label synthesis is unverified);
  bidirectional sync introduces a second writer (must be sequenced with skill
  applies).

**Verdict:** staged adoption — C2 bootstrap → C1 for IL-driven upserts; consider C4
as a later field-drift accelerator (once a release > v1.3.4 ships it), never as the structure channel
(the IL stays the source of truth for hierarchy + superset).

### Axis D — implementation language

- **D1. PowerShell 7 *(recommended)*** — repo standard (`.agents/rules/coding-style.md`
  pwsh-first); JSONL is flat and fully handled by `ConvertFrom-Json`/`ConvertTo-Json`;
  scripts land in the existing skill's `scripts/` style (idempotent, `-DryRun`,
  stdout contracts — the skill's established pattern); **testable by the existing
  Pester gate** (coverage ≥85% as `validation.ps1` actually enforces it); no new
  toolchain, keeps the skill self-contained and copy-portable. The strong-typing
  benefit of D2 is replaced by a Pester round-trip test (emit → `bd import --dry-run`
  → re-read → assert equal) plus an explicit mapping table (§3); IL fixtures in tests
  must use single-quoted here-strings (`@'…'@`) per the Pester-5 gotchas in
  `.agents/rules/validation.md`.
- **D2. Python + Pydantic (parent plan's stated mechanism)** — best-in-class schema
  validation, but: zero Python in the repo today (G15); invisible to
  `validation.ps1`'s test/coverage gate (registering Python means uv + pytest +
  coverage wiring — a bigger change than the feature); breaks the skill's
  "copy `gh-issue-tracking-init/` into another repo and it works" portability unless
  the runtime is vendored/bootstrapped; violates pwsh-first without a
  tool-demands-it justification (the "tool" here — flat JSONL — does not demand it).
- **D3. Python stdlib (no Pydantic)** — same gate/portability cons as D2, fewer
  schema pros. Strictly dominated by D1 for this repo.

### Axis E — packaging / invocation

- **E1. New op scripts inside `gh-issue-tracking-init/scripts/` + driver calls
  *(recommended)*** — e.g. `export-tracking-il.ps1` (hierarchy → IL pair),
  `import-tracking-il.ps1` (IL → GH via existing ops), `ingest-to-beads.ps1`
  (IL → `bd create --graph` / `bd import`). Satisfies "usable outside the skill"
  (scripts are directly invocable, like every other op script); keeps the skill
  self-contained; no new skill-spec surface. Because outside-the-skill users
  hand-author the IL pair, the **authoring contract** is the §3 mapping table plus a
  validating round-trip script (`export-tracking-il.ps1 -Verify <pair>` style) that
  replaces the schema enforcement D2 would have provided. Modifying the skill means
  following `.agents/rules/skills.md`: re-read the Agent Skills spec, update the
  SKILL.md call-sites, and re-run `uvx --from skills-ref agentskills validate`.
- **E2. Separate skill (e.g. `gh-beads-sync`) invoked by gh-issue-tracking-init** —
  better trigger/discoverability if bidirectional beads sync becomes a standalone
  workflow; but duplicates the self-contained-vendoring burden (two copies of the GH
  helpers or a shared dependency — against the skill's no-external-deps rule).
- **E3. Thin separate skill fronting the same scripts** — best of both if E2's use
  case materializes; do E1 now, E3 later if needed (scripts don't move; only a
  SKILL.md wrapper is added).

### Axis F — superset storage (projects / labels / milestones)

- **F1. Sidecar file (`*.gh-meta.json`) *(recommended, with F2)*** — repo-level
  objects (label taxonomy, milestone definitions, project definition incl. fields/
  views) that have no issue line to ride on. Evidence-backed necessity: G5. **The
  pair is the interchange unit**: consuming a `.beads.jsonl` without its sidecar
  silently loses all superset data, so the import/export scripts must enforce the
  pairing (shared run-id + sibling checksum, R10) and refuse a lone file. This also
  separates it from bd's own auto-export `.beads/issues.jsonl` (G10), which must
  never be mistaken for an IL.
- **F2. Per-issue GH attributes in the issue line's `metadata`** *(recommended,
  with F1)* — milestone name, board Status value, level, estimate ride on the node
  they describe and round-trip natively through `bd import`/`bd export` (G4); no
  second addressing scheme for per-issue data.
- **F3. `_type:"memory"` records** — wrong semantics (global agent memory, not
  project data); rejected.

### Axis G — GH ↔ beads identity correlation

- **G1opt. `external_ref` = GH issue URL *(recommended)*** — native field, round-trips
  (G9), and matches what `bd github sync` itself writes (source-read), so a future C4
  adoption finds the links already correct.
- **G2opt. Explicit id-map in the sidecar** *(recommended, complementary)* —
  `{node key → {gh_number, beads_id}}` written back after each apply/ingest; the C2
  graph call returns exactly this map (G7), and `bd import --json` returns created
  ids (G17). Lives in `*.gh-meta.json` (a JSONL file has no "sections"). Makes
  re-syncs deterministic and debuggable without live lookups.
- **G3opt. Numbered-title matching** — keep as the *GH-side* idempotency convention
  (existing skill behavior, stable across runs), never as the beads correlation key;
  the apply/reconcile path cross-checks IL titles against the id-map's live GH
  numbers and fails loudly on mismatch (else an edited title duplicates).
- **G4opt. Id portability policy** *(required decision)* — beads ids are DB-local
  (prefix per database: `bd-scratch-*` vs whatever a target DB mints). An IL moved
  across machines/repos must not blindly re-import foreign ids (upsert-by-id, G4,
  would create wrong-prefix records or collide): the ingest script re-mints via C2
  `--graph` when the IL's id prefix doesn't match the target DB, and `bd create
  --force` (G18) exists for deliberate prefix overrides. Pre-bootstrap IL lines omit
  `id` entirely (import mints ids, G17).

## 5. Recommended composition

**A1 + B2 + B4 + (C2→C1) + D1 + E1 + (F1+F2) + (G1opt+G2opt+G4opt)**, i.e.:

**Scope statement (what "sync back and forth" means here):** v1 delivers both
*one-shot* directions — GH → IL → beads (serialize + ingest) and beads → IL → GH
(B4 export-from-beads + apply) — with the IL pair as the durable artifact between
them. *Continuous field-drift* synchronization (edits in beads propagating
automatically, and vice versa) is **deferred** to a possible C4 adoption — which now
means a **future bd release > v1.3.4** (the installed latest release does not yet
contain the sub-issue link sync, G12); until then drift is handled by re-running the
IL apply/reconcile path (B3).
This satisfies parent-plan reqs 1–3 and the "usable outside the skill" clause; the
"intermediate language for syncing back and forth" clause is met at IL granularity,
not at live-sync granularity — an explicit deviation to record if the parent wants
more.

1. **IL = a file pair** written by one serializer run:
   `<name>.beads.jsonl` (pure, importable — parent-plan §6 verbatim; pre-bootstrap
   lines omit `id`, G17) + `<name>.gh-meta.json` (label/milestone/project
   definitions, campaign provenance, id-map). Per-issue GH data in each issue line's
   `metadata` + `external_ref`. The pair is atomic and mandatory together (F1, R10).
2. **The skill becomes IL-first** (B2): resolve campaign anchor first → parse plan →
   render bodies into the IL → DryRun assertions over the IL's rendered
   `description`s (existing filler/secret guards) → apply drives the existing op
   scripts from the IL → write back GH numbers (`external_ref`, id-map) → apply the
   run-scoped `init-success` label. Numbering and campaign continuation stay live-GH
   driven (provenance recorded in the sidecar), never replayed from a stale IL.
3. **Beads bootstrap**: `bd create --graph` from the IL nodes/edges (one call, id map
   captured into the sidecar); **subsequent syncs**: `bd import` the `.beads.jsonl`
   (upsert-by-id). Id portability per G4opt (re-mint on prefix mismatch). Manual `bd`
   driving (parent plan §7) stays as a documented fallback only.
4. **PowerShell 7 op scripts** in the skill's `scripts/` (export/import/ingest above),
  Pester-tested (single-quoted here-strings for JSONL fixtures) and registered in
  `validation.ps1`'s test/coverage paths **and the CI workflow's mirrored paths**
  (keeps the ≥85% gate real). A round-trip Pester test (IL → `bd import --dry-run` →
  export → compare) replaces Pydantic's schema enforcement. Skill changes follow
  `.agents/rules/skills.md`: spec re-read, SKILL.md call-site update, official
  validator re-run.
5. **Adopt `bd github sync` only after a release > v1.3.4 ships `links.go`** (track
   upstream releases; G12) and only as a field-drift accelerator; the IL remains the
   hierarchy/superset channel. Verify the `--parent` push hint (G11) and configure
   `github.label_map` (upstream-documented) if adopted, to stop `type::`/`priority::`
   scoped-label conventions colliding with the skill's `plan/epic/story/task` +
   `P0..P3` taxonomy.

**Parent-plan amendments this composition requires (sign-off needed):**

- The parent plan's stated mechanism — "Python scripting with Pydantic definitions" —
  is **not** adopted (D2 rejected on G15 evidence: no Python toolchain, invisible to
  the validation/coverage gate, breaks skill self-containment). D1 replaces it; the
  schema discipline moves to Pester round-trip tests + the §3 mapping table. If the
  parent's Python requirement is a hard constraint, D2's extra infrastructure (uv +
  pytest + coverage wiring in `validation.ps1`) must be budgeted as its own work
  item — it is larger than the sync feature itself.
- The parent plan's §5 "superset … consider writing these to a separate second file"
  consideration is resolved to **yes, separate file** (G5 makes the single-file
  variant corrupting, not just risky).

**Why this composition wins:** it is the only one where the IL is simultaneously
(a) what the skill can capture and replay to GH (req 1–2), (b) literally what beads
imports and exports (req 3–4 — no translation layer anywhere), and (c) safe against
the verified superset corruption (G5) — while staying inside the repo's pwsh/Pester/
validation regime (G15) instead of founding a Python toolchain for a flat JSONL job.
The parent plan's own §6 ("Support `bd import --file github_issues.jsonl`") is the
strongest signal that A1, not a custom schema, is the intended shape.

## 6. Risks & open questions

| # | Risk / question | Mitigation / decision needed |
|---|---|---|
| R1 | ~~bd version skew~~ → **resolved by the 2026-11-04 upgrade to v1.3.4** (latest release): import staleness guard, rich `--graph` fields, and arbitrary-JSON metadata now all present. **Remaining skew:** sub-issue/blocked_by sync (`links.go`) is on `main` ahead of v1.3.4 — C4 stays blocked on a future release (G12); also probe sync's `--parent` push semantics (G11) when that lands | Watch upstream releases for the first tag containing `internal/github/links.go`; until then the IL path (C2→C1) is the only hierarchy channel |
| R2 | `--graph` non-idempotent (G8) | Bootstrap-only by construction: ingest script refuses to run when the IL already carries beads ids (guard via export + external_ref filter, G13) |
| R3 | Two writers (skill apply + future `bd github sync`) racing | Sequence: one writer per run; IL records last-sync provenance |
| R4 | Status mapping is not 1:1 (§3) — `In Review` has no beads status; board Status ≠ issue state | Define one mapping table in the IL spec; rule: GH board authoritative, beads mirrors (`In Review` → beads `in_progress` + metadata marker, or upstream custom status) |
| R5 | Level↔`issue_type`: beads has no `plan`/`story` types | Keep levels as GH-style labels in beads; map only `epic` → `issue_type:"epic"` (avoids `types.custom` config drift across machines) |
| R6 | Where does the IL pair live, and is it committed? | Recommend a committed, campaign-addressed path (e.g. `docs/tracking/<campaign>.beads.jsonl` + `.gh-meta.json`) so re-syncs and reviews use the artifact; `.beads/issues.jsonl` stays bd-owned (auto-export, G10) — never write the IL there |
| R7 | `.beads/` Dolt DB in target repos: committed or ignored? **1.3.4 change:** `export.auto` now defaults to **false** (G10) — the git-tracked `.beads/issues.jsonl` no longer appears automatically on writes | `.gitignore` today has no beads entry; decide policy. If tracked state is wanted: enable `export.auto` or export explicitly (`bd export -o .beads/issues.jsonl`) — the IL pair (R6) is separate and must not live at that path either way |
| R8 | New pwsh scripts must clear PSScriptAnalyzer (Error-severity) and be registered in `validation.ps1` `$testPaths`/`$coveragePaths` **and the CI workflow's mirrored paths** or the ≥85% gate won't see them; JSONL test fixtures need single-quoted here-strings (Pester gotcha) | Part of the implementation checklist, not an afterthought |
| R9 | ~~`metadata` string-only at 1.0.4~~ → **resolved on 1.3.4**: metadata is arbitrary JSON, preserved verbatim (live-verified) | No action; structured per-issue GH attributes may ride in metadata directly |
| R10 | IL atomicity (two files); a lone `.beads.jsonl` mistaken for the IL silently drops the superset | Produce/consume the pair together; embed a shared run-id + checksum of the sibling file in each; the import/export scripts **refuse a lone file** |
| R11 | IL portability: beads ids are DB-local (prefix per database); naive re-import upserts foreign ids (G4) | G4opt id policy: pre-bootstrap lines omit `id`; ingest re-mints via `--graph` on prefix mismatch; `bd create --force` (G18) for deliberate overrides |
| R12 | Committed IL pairs in the **parent template** repo: this repo is the clone stamper (GitHub template route) — committed tracking artifacts ride into every clone, and bodies/URLs must stay gitleaks-clean through `/safe-commit` | Decide parent-vs-clones policy: likely track IL pairs only in campaign clones/repos being tracked, not in the parent template; run `assert-no-secrets.ps1` over IL bodies as part of the serializer (already a B2 DryRun assertion) |

## 7. Options at a glance

| Axis | Option | Verdict |
|---|---|---|
| A — IL format | A1 native export JSONL + sidecar | ✅ **recommended** |
| | A2 single mixed superset file | ❌ rejected (G5 — silent garbage import) |
| | A3 `--graph` plan JSON | ➖ bootstrap format only (C2) |
| | A4 custom Pydantic schema | ❌ third format + new runtime (see D2) |
| B — skill binding | B1 emit-only | ❌ fails parent-plan req 2 |
| | B2 IL-first driver | ✅ **recommended** |
| | B3 dual-mode (adopt/diff existing) | ⏳ follow-on |
| | B4 beads-first adoption (export → merge sidecar → GH) | ✅ **v1 scope** (req 4 "export from beads") |
| C — beads transport | C1 `bd import` upsert | ✅ sync path |
| | C2 `bd create --graph` | ✅ bootstrap path |
| | C3 manual `bd` commands | ➖ documented fallback only |
| | C4 native `bd github sync` | ⏳ blocked until a release > v1.3.4 (`links.go` is main-only); field drift only |
| D — language | D1 PowerShell 7 | ✅ **recommended** |
| | D2 Python + Pydantic | ❌ conflicts with repo rules/gates (G15) |
| | D3 Python stdlib | ❌ dominated by D1 |
| E — packaging | E1 op scripts in existing skill | ✅ **recommended** |
| | E2 separate skill | ⏳ if standalone workflow emerges |
| | E3 thin skill over same scripts | ⏳ growth path from E1 |
| F — superset | F1 sidecar gh-meta file | ✅ **recommended** (with F2) |
| | F2 per-issue `metadata` | ✅ **recommended** (with F1) |
| | F3 memory records | ❌ wrong semantics |
| G — identity | external_ref (URL) + sidecar id-map | ✅ **recommended** |
| | title matching | GH-side idempotency only, id-map cross-checked |
| | id portability policy (re-mint on prefix mismatch) | ✅ **required** (R11) |

## 8. Review adjudication (post-survey review wave + post-upgrade re-verification)

Three read-only reviewers examined this survey (bd-fact verification with live
re-experiments; requirements/holes vs the parent plan; repo-rules compliance).
Findings and their resolutions:

1. **Ground-truth corrections** — the `bd dep add` dependency-type enum is now quoted
   from live help rather than the longer source-read type list (G2); memory import
   requires the canonical `{key,value}` shape (G6); `github.label_map` and the
   `links.go` release boundary are explicitly tagged unverified-on-1.0.4 (C4, R1);
   sync's `--parent` flag flagged for probing (G11). All other G-rows re-confirmed by
   independent re-experiment (including G5 garbage-import and G8 graph duplication).
2. **Missing direction (P1)** — beads→GH had no option; added **B4** and the §5 scope
   statement distinguishing one-shot both-direction IL sync (in v1) from continuous
   field-drift sync (deferred to C4).
3. **Id portability (P1)** — added **G4opt** + **R11** (pre-bootstrap id-less lines
   per G17, re-mint on prefix mismatch, `--force` for overrides).
4. **Parent-plan deviation flagged (P2)** — §5 now carries an explicit
   "Parent-plan amendments" block (Python+Pydantic not adopted; separate-file
   superset resolved to yes).
5. **Skill-compatibility holes (P2)** — B2 now mandates campaign-anchor resolution
   before IL generation + provenance in the sidecar; rendered bodies in the IL before
   DryRun; run-scoped `init-success` label; B3 gets the title/id-map cross-check.
6. **Rules-compliance (P2/P3)** — E1 adds the skills-spec re-validation step and the
   standalone authoring contract; R8 adds CI path mirroring + the Pester here-string
   gotcha; R10 makes the pair-mandatory rule explicit; R12 added (template-repo
   artifact policy); coverage wording aligned to ≥85% as actually enforced;
   markdownlint confirmed **not** to lint `docs/plans/**` (checked anyway — tables
   are well-formed GFM).
7. **Post-upgrade re-verification (bd 1.0.4 → 1.3.4, same day)** — the installed
   binary was upgraded to v1.3.4 (latest release, published 2026-11-04) and every
   load-bearing fact was re-tested live in a fresh scratch DB
   (`/tmp/kilo/swarm-context/bd-scratch134/`):
   - **Still true on 1.3.4** (recommendations unchanged): unknown-`_type`
     garbage-import (G5 — the sidecar stays mandatory), `--graph` non-idempotency
     (G8), upsert-by-id (G4), export/edge schema incl. `parent-child` (G1–G3),
     memory `{key,value}` shape (G6), no `external_ref` query filter (G13).
   - **Improved on 1.3.4** (recommendations strengthened): import staleness guard +
     `--allow-stale` + bounded dependency-ordered transactions + structured `--json`
     (G14, C1); `--graph` nodes accept `status`/`external_ref`/`estimated_minutes`/
     arbitrary-JSON `metadata` (G7); `metadata` arbitrary JSON everywhere (R9
     resolved).
   - **Corrected**: G12 — sub-issue/blocked_by sync (`links.go`) is **main-only,
     NOT in v1.3.4** (verified via tagged tree listing + grep at refs `v1.3.4` and
     `main`); the earlier "≥ ~1.3.x" attribution was wrong, so C4 stays blocked on a
     future release. `export.auto` default flipped true → **false** (G10, R7).

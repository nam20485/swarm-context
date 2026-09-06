---
name: update-powershell-standard
description: Use when refreshing the vendored PowerShell Engineer Standard rules hierarchy from upstream (powershellengineer.com) — checking for upstream version bumps, re-splitting the monolithic upstream AGENTS.md into topic files under .agents/rules/powershell/, or repairing a corrupted/stale generated tree. Trigger when the user asks to "update the PowerShell standard", "check for standard updates", "refresh the rules hierarchy", or when an agent notices .agents/rules/powershell/ is missing or out of sync with the version stamped in .agents/rules/powershell.md.
compatibility: Requires PowerShell 7+ (pwsh). Network access only for the default fetch path; use -SourceFile for offline refreshes.
---

# update-powershell-standard

Refreshes the vendored PowerShell Engineer Standard rules hierarchy
(`.agents/rules/powershell/*.md`) from the upstream monolithic
`AGENTS.md` published at <https://www.powershellengineer.com/AGENTS.md>.
The whole operation is one script call:

```bash
pwsh .agents/skills/update-powershell-standard/scripts/update-powershell-standard.ps1
```

## When to run

- An upstream version bump is suspected or reported.
- A periodic check is due (upstream updates are infrequent; monthly is plenty).
- The generated tree is missing or corrupted — run with `-Force` to regenerate
  even when versions match.
- The user asks for a corpus refresh.

## Decision guidance

- The script compares the upstream `**Version:** x.y.z` line against the version
  stamped in the index `.agents/rules/powershell.md` and **no-ops when they
  match** (unless `-Force`). You do not need to eyeball versions yourself.
- `-CheckOnly` reports whether an update is available **without writing
  anything** — use it when the user only asked "is there a new version?".
- What gets regenerated: every topic file under `.agents/rules/powershell/`
  (wholesale replacement, write-only-on-change) and the single version line in
  the index. **House content lives only in the hand-maintained index
  `.agents/rules/powershell.md`** — topic files are generated, never
  hand-edited.
- If upstream adds or removes a top-level section, the script **fails loudly**
  (the section→file map no longer matches). That is deliberate: a human must
  update the map in the script, not silently mis-file content.

## Call sites

| Goal | Command |
|---|---|
| Standard refresh (fetch + split + stamp) | `pwsh <script>` (no flags) |
| Check only, no writes | `pwsh <script> -CheckOnly` |
| Force re-split at same version | `pwsh <script> -Force` |
| Offline / fixture-driven refresh | `pwsh <script> -SourceFile ./local.md` |

`<script>` = `scripts/update-powershell-standard.ps1` relative to this skill's
directory (full: `.agents/skills/update-powershell-standard/scripts/update-powershell-standard.ps1`).

The script emits a `PSEStandard.RefreshSummary` object (status, version delta,
files written/unchanged, index-stamped flag) — report that summary to the user.
After a refresh that changed files, run markdownlint on `.agents/rules/**/*.md`
(lint globs already cover it) and commit the regenerated tree separately from
any hand-edits.

Upstream content is MIT-licensed (Jim Tyler, powershellengineer.com); the
generated-by header in every topic file carries the attribution.

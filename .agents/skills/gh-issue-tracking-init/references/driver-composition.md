# Driver composition (delegation performance)

Operational rules for composing the orchestration driver of a
`gh-issue-tracking-init` run — **read this before composing the driver**.
`SKILL.md` keeps a one-line digest of each rule; this file carries the full
rationale and code blocks, distilled from forensic runs (see git history and
`.agents/memory.md`).

## Delegation performance (batching)

### Scratch workspace — isolate the run under `/tmp/kilo/<repo-slug>/`

A composed `gh-issue-tracking-init` run writes several artifacts: a PowerShell driver, rendered issue bodies, trace logs, and diagnostic scripts. Put them all under the per-repo scratch namespace from [`.agents/rules/tools.md`](../../../rules/tools.md) — `/tmp/kilo/<repo-slug>/` — **not** loose in a flat `/tmp/kilo/`:

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
the plan. See [Body composition specification](../SKILL.md#body-composition-specification) above for
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
**once** on the Plan body — see [Canonical cross-cutting content](../SKILL.md#canonical-cross-cutting-content).

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

### Keep every tool call under the idle window: chunk the apply and stream driver liveness

Observed live on charlie68 run `df4c8f2d`: the board/milestone apply ran as ONE
redirected bash call (`pwsh … > apply-runN.log 2>&1`) and was killed at **302 s**
mid-board-onboarding. The receiver's idle watchdog has exactly two liveness signals —
session status updates and harness stderr lines. During a >300 s apply that streams
nothing, both go quiet and the watchdog kills a **live** run. Two rules prevent this;
both are mandatory when composing the driver:

**(a) The composed apply must NEVER redirect output to a file-only sink.** `> log 2>&1`
is banned in the driver invocation. The per-op progress lines (`Write-Step` /
`Write-Ok` / `Write-Skip` from `scripts/common.ps1`) must **stream live** to stdout so
the dispatching session observes them and emits status between ops, feeding the
watchdog. When a persisted copy of apply output is wanted for forensics, use
`Tee-Object` (stream AND capture), never a redirect-only invocation:

```pwsh
# GOOD: streams to the caller's stdout AND persists a copy
& pwsh -NoProfile -File $driver -Phase epic | Tee-Object -FilePath $applyLog
# BANNED: file-only sink — the watchdog sees nothing for the whole call
& pwsh -NoProfile -File $driver -Phase epic > $applyLog 2>&1
```

**(b) Chunk the apply per epic.** Do not run board onboarding as one monolith. Split it
into per-epic chunk invocations — for a 7-epic plan, ~7 driver invocations of ~40 s
each — so no single tool call outlives the smallest idle window (the receiver default
`ACP_IDLE_TIMEOUT` is 300 s). Between chunks the dispatching session observes the
chunk's streamed output and emits a status update, which re-arms the watchdog:

```pwsh
foreach ($epic in $epics) {   # $epics ordered by dependency, same as the issue map
    & pwsh -NoProfile -File $driver -Epic $epic.Title | Tee-Object -FilePath "$($epic.Slug).log"
    Start-Sleep -Milliseconds 500
}
```

If a chunk fails, the streamed per-op lines tell you exactly which op died — a
file-only redirect of the whole monolith tells you nothing until you open the log after
the kill.

### PowerShell variable names are case-insensitive: never ship a `$Num`/`$num` pair

PowerShell variable names are **case-insensitive** — `$Num` and `$num` are the SAME
variable. Observed live on charlie68 run `8a809037`: the generated `07-execution.ps1`
assigned under one casing and read under the other, so the read silently returned an
empty value, and the run had to self-fix it live. The symptom signature: an assignment
under one case, a read under the other, and a downstream parameter binding that gets
nothing without any error.

Prescription: use **distinct names** for distinct things — `$IssueNum` for an issue
number, `$MilestoneNum` for a milestone — and never a bare `$Num`. Audit the composed
driver for case-colliding names before the apply (DryRun pass):

```pwsh
$names = Select-String -LiteralPath $driver -Pattern '\$[A-Za-z_][A-Za-z0-9_]*' -AllMatches |
    ForEach-Object { $_.Matches.Value } | Sort-Object -Unique
$collisions = $names | Group-Object { $_.ToLowerInvariant() } |
    Where-Object { ($_.Group | Sort-Object -Unique).Count -gt 1 }
if ($collisions) { throw "Case-insensitive variable collision in driver: $($collisions.Name -join ', ')" }
```


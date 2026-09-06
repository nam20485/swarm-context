# Plan: Resolve PR #15 Review Comments — Round 3

## Unresolved Threads

| # | Thread ID | File | Severity | Issue |
|---|-----------|------|----------|-------|
| 1 | `PRRT_kwDOTFv2cM6VSHck` | `.github/CODEOWNERS` | P1 | Stale docs reference deleted `.github/` health files |
| 2 | `PRRT_kwDOTFv2cM6VSHco` | `.opencode/agents/orchestrator.md` | P1 | Orchestrator direct web access security concern |
| 3 | `PRRT_kwDOTFv2cM6VSHcp` | `.opencode/opencode.jsonc` | P1 | Unpinned MCP server npm packages (supply-chain risk) |

---

## Thread 1: Stale docs after `.github/` deletion (`PRRT_kwDOTFv2cM6VSHck`)

**Reviewer concern**: `.agents/memory.md` and `docs/plans/.completed/template-content-strategy.md` still reference `.github/CODEOWNERS` and issue templates that this PR deletes.

### Changes

**`.agents/memory.md` line 12**: Append a note that these files were subsequently removed in this PR. Change:

```
...Closes `codeowners`, `issue_templates`, `pr_templates`, ...
```

to:

```
...Closes `codeowners`, `issue_templates`, `pr_templates`, ... (CODEOWNERS and issue form templates subsequently removed — see Decisions below.)
```

Then add a new Decision entry under `## Decisions`:

```
- **Removed `.github/CODEOWNERS` and issue form templates** (2026-07-30): Deleted `.github/CODEOWNERS` and the 4 `ISSUE_TEMPLATE/` files (`bug_report.yml`, `feature_request.yml`, `task.yml`, and `config.yml`). CODEOWNERS was a single-owner repo where the sole maintainer was also the only code owner, adding no review value. Issue form templates were replaced by the gh-issue-tracking-init skill's programmatic issue creation, which uses the GitHub API directly and does not need form templates.
```

**`docs/plans/.completed/template-content-strategy.md` lines 116-119**: Update the bullet to note these files were removed. Change:

```
- Special `.github/` files transfer *and activate* in the clone: `CODEOWNERS`,
  `ISSUE_TEMPLATE/`, `FUNDING.yml`, `workflow-templates/` (starter Actions
  workflows). Org-level `/.github/` default community-health files are a separate
  fallback.
```

to:

```
- Special `.github/` files transfer *and activate* in the clone: `FUNDING.yml`,
  `workflow-templates/` (starter Actions workflows). `CODEOWNERS` and
  `ISSUE_TEMPLATE/` were removed from this template (2026-07-30). Org-level
  `/.github/` default community-health files are a separate fallback.
```

---

## Thread 2: Orchestrator web access (`PRRT_kwDOTFv2cM6VSHco`)

**Reviewer concern**: Allowing `webfetch`/`websearch` and MCP web tools removes the safety boundary, creating prompt-injection and data-exfiltration risk.

**Resolution**: No code change needed. This was an explicit user design decision made in round 2 — the user chose to allow all web tools for the orchestrator, accepting the risk. The reviewer's security concern is valid but the decision is intentional. Reply explaining the decision and resolve.

---

## Thread 3: Pin MCP server npm packages (`PRRT_kwDOTFv2cM6VSHcp`)

**Reviewer concern**: `npx -y @modelcontextprotocol/server-*` without version pins is a supply-chain RCE risk.

### Changes

**`.opencode/opencode.jsonc`**: Pin both MCP server packages to their current latest version (`2026.7.4`).

Line 19 (sequential-thinking):
```json
"command": ["npx", "-y", "@modelcontextprotocol/server-sequential-thinking@2026.7.4"],
```

Line 22 (memory-graph):
```json
"command": ["npx", "-y", "@modelcontextprotocol/server-memory@2026.7.4"],
```

---

## Implementation Steps

1. Edit `.agents/memory.md` — update line 12, add Decision entry
2. Edit `docs/plans/.completed/template-content-strategy.md` — update lines 116-119
3. Edit `.opencode/opencode.jsonc` — pin both MCP packages to `@2026.7.4`
4. Commit and push: `fix: update stale docs for deleted .github files, pin MCP server versions`
5. Reply to thread 1: explain the doc updates
6. Reply to thread 2: explain this was an explicit user decision, no code change
7. Reply to thread 3: explain the version pins
8. Resolve all 3 threads via GraphQL
9. Leave summary comment on PR
10. Verify 0 unresolved threads remain

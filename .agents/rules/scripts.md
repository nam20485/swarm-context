# Repository Scripts

Automation scripts under the repo-root [`scripts/`](../../scripts/) directory — GitHub CLI helpers for authentication, label synchronization, PR review-thread management, permission verification, orchestrator dispatch, and remote-instruction-module index regeneration. Most scripts accept a `-DryRun` switch so actions can be previewed without mutation.

The two most-used: `query.ps1` (canonical PR review-thread list/reply/resolve via GraphQL — do not rewrite ad hoc) and `import-labels.ps1` (idempotent label sync from a JSON export).

## Script inventory

Built from each script's header comments and `param()` block. **Read the file header and `param()` block in the script itself for authoritative parameter documentation, examples, and `NOTES`** — the table below is a quick-reference only.

| Script | Purpose | Key parameters |
| --- | --- | --- |
| `common-auth.ps1` | Dot-sourceable `gh` auth bootstrap (`Initialize-GitHubAuth`). Verifies `gh` is on PATH and triggers `gh auth login` if unauthenticated. | `-DryRun` |
| `gh-auth.ps1` | `gh` auth bootstrap with non-interactive PAT-stdin support (`gh auth login --with-token`). Falls back to interactive login. | `-DryRun`, `-Token <pat>` |
| `import-labels.ps1` | Syncs labels from a JSON export into a target repo: creates missing labels, updates color/description when they differ, optionally deletes labels not in the source. | `-Repo <owner/repo>`, `-LabelsFile ./.labels.json`, `-DryRun`, `-DeleteMissing` |
| `query.ps1` | PR review-thread management via GraphQL — list unresolved threads, post a reply to each, then resolve. **Canonical tool** for resolving PR review comments; do not write ad-hoc Python/shell for this. | `-Owner`, `-Repo`, `-PullRequestNumber`, `-ThreadId`, `-Path <wildcard>`, `-BodyContains`, `-Interactive`, `-AutoResolve`, `-NoResolve`, `-DryRun`, `-VerboseLogging`, `-ReplyEach "<msg>"` |
| `create-dispatch-issue.ps1` | Creates a GitHub issue on a target repo, defaulting the title to `orchestrate-dynamic-workflow` so it triggers the orchestrator match clause. Title/body can be overridden for arbitrary issue creation. | `-Repo <owner/repo>`, `-Title`, `-Body <text>`, `-Labels[]`, `-Project`, `-Milestone`, `-Template`, `-Assignee[]`, `-DryRun` |
| `test-github-permissions.ps1` | End-to-end verifier: `gh` auth status, scopes (`user:email`, `repo`, `project`), repo create/delete, project create, label/milestone/branch-permission workflow. Optional auto-fix for missing scopes. | `-Owner <user>`, `-TestRepoName`, `-TestProjectName`, `-Cleanup`, `-AutoFixAuth` |
| `update-remote-indices.ps1` | Regenerates the two `local_ai_instruction_modules/` index files from the remote canonical `nam20485/agent-instructions` repo listing (only writes if content changed). | `-Owner <owner>`, `-Repo <repo>`, `-Branch <branch>` |

## Generating a labels export

`import-labels.ps1` consumes a JSON file produced by:

```bash
gh api repos/{owner}/{repo}/labels --paginate > .labels.json
```

## Common conventions

- `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'` are active in the auth-aware scripts; treat missing properties via `PSObject.Properties` (not direct member access).
- Auth-aware scripts dot-source `common-auth.ps1` (or `gh-auth.ps1`) if present and call `Initialize-GitHubAuth` before doing any API work.
- `-Repo` parameters validate `^[^/]+/[^/]+$` (`owner/repo` form).

## Note on `scripts/` vs the gh-issue-tracking skill's `scripts/`

The `.agents/skills/gh-issue-tracking-init/scripts/` directory is a **separate, self-contained** set of operation scripts (vendored copies of the generic helpers plus skill-specific ops). It is documented in that skill's own [`scripts/README.md`](../skills/gh-issue-tracking-init/scripts/README.md), not here.

## Note on `tmp-issue-body-project-setup.txt`

`scripts/tmp-issue-body-project-setup.txt` is a kept scratch file — a staged draft of the `-Body` payload for a `create-dispatch-issue.ps1` project-setup dispatch. It is **not** a script and is **not** consumed by anything (`create-dispatch-issue.ps1` takes `-Body` as a string argument, not a file); it is retained as a reference example of a dispatch body.

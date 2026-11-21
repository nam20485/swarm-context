# Source Control

## Safe Commit

- Always run the `/safe-commit` skill before committing.

## Commit Workflow

When asked to commit the current set of changes in the working copy, always:

1. Run `validation.ps1` first; proceed only if it passes.
2. Break the changes into conceptual groups.
3. Commit each group with a meaningful message.

## Monitor Workflows

- After pushing, monitor the workflows to ensure they are running as expected.
- If a workflow fails, investigate and fix the issue before proceeding.
- Repeat the process until all workflows are running as expected.

## Branching

- Create a new branch for each feature or bug fix.
- Use a descriptive branch name that reflects the work being done.
- Use the form `<base-branch-prefix>/<branch-name>`, i.e. `mn/new-feature` or `dev/<branch-name>`.

## Pull Requests

- Create a pull request for each branch.
- Use a descriptive title and description that reflects the work being done.
- **Always set a milestone** when creating a pull request.
- **Always set the project** (assign to the active Projects v2 board) when creating a pull request.
- Request a review from the appropriate team member before merging.
- Once reviews have left comments, address all comments before merging.
- For each comment that is addressed, leave a comment explaining the resolution and mark the thread as RESOLVED state.
- ADDRESS ALL COMMENTS BEFORE MERGING.

## Merge readiness

No session certifies its own pull request ready to merge. Before ANY merge call:

1. **Independent verification** — dispatch TWO verifier subagents (separate
   from any code reviewers) that each run the checklist below and report the
   RAW command output as evidence. Merge only when both verifiers agree on
   every field, and quote their evidence in the merge status comment.
2. **The checklist** (exact commands, expected results):
   - `gh pr view <n> --json state,mergeable,mergeStateStatus,baseRefName,headRefOid`
     → `state=OPEN`, `mergeable=true`, `mergeStateStatus=CLEAN`, base = the
     repo's default branch; record `headRefOid` (the head commit SHA).
   - `gh api repos/<owner>/<repo>/commits/<headRefOid>/check-runs` → EVERY
     check run for THAT EXACT SHA: `status=COMPLETED` and
     `conclusion=SUCCESS`. `conclusion=SKIPPED` is acceptable only for a
     check documented as inert; any FAILURE, TIMED_OUT, CANCELLED, or
     still-running check = NOT READY. Checks on an older SHA are stale —
     re-verify after any push.
   - Unresolved review threads on the PR = 0 (GraphQL `reviewThreads`,
     filter `isResolved == false`).
3. **Merge method**: merge-commit only (`gh pr merge --merge`). Squash and
   rebase are disabled by branch protection on orchestrated clones.

Branch protection (stamped at clone creation) is the mechanical backstop: if
GitHub refuses the merge, a gate condition is genuinely unmet — re-verify,
fix, or park with `needs-owner`; never force or work around it.

## Resolving review comments

When resolving PR review comments (automatically or manually), follow this sequence for **every** unresolved thread:

1. **Analyze** the comment. If no code change is needed (functionality works as designed, comment is outdated, etc.), skip to step 3 and explain why no change is warranted.
2. **Make the code change**, commit, and push.
3. **Reply to the comment thread** with a summary of the fix or the reason no change was needed. Use the GraphQL `addPullRequestReviewThreadReply` mutation (or `gh pr comment` for non-thread comments) so the reply is attached to the thread.
4. **Mark the thread as RESOLVED** via the GraphQL `resolveReviewThread` mutation (or the GitHub REST API equivalent). Do not leave threads open after replying.

```graphql
# Reply to a review thread
mutation {
  addPullRequestReviewThreadReply(input: {
    pullRequestReviewThreadId: "<thread-id>"
    body: "Fixed: <summary of change>"
  }) { comment { id } }
}

# Resolve the thread
mutation {
  resolveReviewThread(input: {
    threadId: "<thread-id>"
  }) { thread { id isResolved } }
}
```

After resolving all threads, verify zero unresolved comments remain by querying `reviewThreads` and filtering `isResolved == false`. Leave a final summary comment on the PR listing all resolved threads and their fixes.

<!-- canary: indigo-badger-4 -->

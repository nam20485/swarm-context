#!/bin/sh
# SwarmSandbox M2 entrypoint: clone REPO_URL into /workspace, then keep the
# container alive so the ZCode desktop can connect via `docker exec`.
#
# Contract (passed by M1's provisioner as environment):
#   REPO_URL          required
#   WORKSPACE_BRANCH  optional, default "development"
#   GIT_TOKEN         optional; when set, clone via
#                     https://x-access-token:$GIT_TOKEN@host/... then scrub the
#                     token from /workspace/.git/config with `git remote
#                     set-url` and delete /workspace/.git/FETCH_HEAD (clone
#                     wrote the credentialed URL there too), and re-exec PID1
#                     without GIT_TOKEN. Never echoed, never logged.
#                     REPO_URL itself must be token-free: it is logged and
#                     re-written into .git/config.
#
# On clone failure: write /workspace-clone-error.txt and still keep the
# container alive (desktop connect must remain possible for debugging).
set -eu

REPO_URL="${REPO_URL:-}"
WORKSPACE_BRANCH="${WORKSPACE_BRANCH:-development}"
GIT_TOKEN="${GIT_TOKEN:-}"
WORKSPACE=/workspace
ERROR_FILE=/workspace-clone-error.txt

log() {
    printf '[sandbox-entrypoint] %s\n' "$*"
}

# Records a failure. The error file is pre-created in the image and owned by
# 'sandbox'; write failures are ignored so the container still stays up.
fail() {
    log "ERROR: $*"
    {
        printf 'sandbox entrypoint failure\n'
        printf 'utc: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf 'REPO_URL=%s\n' "$REPO_URL"
        printf 'WORKSPACE_BRANCH=%s\n' "$WORKSPACE_BRANCH"
        printf 'error: %s\n' "$*"
    } >>"$ERROR_FILE" 2>/dev/null || true
}

if [ -z "$REPO_URL" ]; then
    fail "REPO_URL is required (WORKSPACE_BRANCH defaults to 'development')."
    exec env -u GIT_TOKEN sleep infinity
fi

if [ -d "$WORKSPACE" ] && [ -n "$(ls -A "$WORKSPACE" 2>/dev/null)" ]; then
    log "Workspace $WORKSPACE is already non-empty; skipping clone."
else
    # Build the clone URL. Only REPO_URL (token-free) is ever logged.
    clone_url="$REPO_URL"
    if [ -n "$GIT_TOKEN" ]; then
        case "$REPO_URL" in
            https://*) clone_url="https://x-access-token:${GIT_TOKEN}@${REPO_URL#https://}" ;;
            http://*) clone_url="http://x-access-token:${GIT_TOKEN}@${REPO_URL#http://}" ;;
            *) log "GIT_TOKEN set but REPO_URL is not an http(s) URL; using REPO_URL as-is." ;;
        esac
    fi

    log "Cloning branch '$WORKSPACE_BRANCH' from $REPO_URL into $WORKSPACE (--single-branch --depth 1)."
    if git clone --branch "$WORKSPACE_BRANCH" --single-branch --depth 1 "$clone_url" "$WORKSPACE"; then
        if [ -n "$GIT_TOKEN" ] && [ -f "$WORKSPACE/.git/config" ]; then
            # Scrub the embedded credential: rewrite origin to the token-free URL and
            # drop FETCH_HEAD, where clone also wrote the credentialed URL.
            # (REPO_URL itself must always be token-free: it is logged and re-written
            # into .git/config here.)
            if (cd "$WORKSPACE" && git remote set-url origin "$REPO_URL"); then
                rm -f "$WORKSPACE/.git/FETCH_HEAD"
                log "Scrubbed credentials from $WORKSPACE/.git/config."
            else
                rm -f "$WORKSPACE/.git/FETCH_HEAD"
                fail "git remote set-url (token scrub) failed; inspect $WORKSPACE/.git/config manually."
            fi
        fi
        log "Workspace clone complete."
    else
        fail "git clone --branch '$WORKSPACE_BRANCH' --single-branch --depth 1 failed. Keeping container alive for debugging."
    fi
fi

# Re-exec PID1 without GIT_TOKEN so the credential does not live in the init
# environment for the container's lifetime.
exec env -u GIT_TOKEN sleep infinity

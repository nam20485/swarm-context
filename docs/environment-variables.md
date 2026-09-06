# Environment Variables

This document lists every environment variable that must (or may) be defined in the
environment where instances cloned from this template repository are run. It is
intended for the platform/operations team that provisions those downstream clone
environments (e.g. the `orchestrator-service` repos).

These variables are consumed by two categories of code that ship in the template:

1. **Agent runtime config** — `.opencode/opencode.jsonc` (MCP servers and model providers).
2. **Repo automation scripts** — `scripts/*.ps1` (GitHub auth, label sync, index refresh,
   permission checks).

Clone environments should define at minimum the **Required** variables below so that the
shipped tools and scripts function without error.

---

## Required

| Variable | Used by | Purpose |
|---|---|---|
| `EXA_API_KEY` | `.opencode/opencode.jsonc` — Exa MCP server | Exa neural web search, code-context lookup, and crawling tools. Sent via the `x-api-key` request header (kept out of the MCP server URL to avoid disclosure via logs/proxies). |
| `Z_AI_API_KEY` | `.opencode/opencode.jsonc` — Z.AI MCP servers | `Authorization` header for the Z.AI MCP servers (`web-search-prime`, `web-reader`, `zread`). Must be the full `Authorization` header value including the `Bearer` prefix (e.g. `Bearer <api-key>`) — opencode substitutes the variable verbatim. If you run without `auth.json` and need the `zai-coding-plan` provider env fallback, set `ZAI_CODING_PLAN_OPEN_AI_API_KEY` separately to the raw key to avoid conflicts. |
| `GITHUB_AUTH_TOKEN` | `scripts/gh-auth.ps1`, `scripts/test-github-permissions.ps1` | Primary GitHub auth token used by repo automation scripts. |
| `GITHUB_USERNAME` | `scripts/test-github-permissions.ps1` | Default repository owner used when running permission checks. |

> **Note on GitHub auth:** `GITHUB_TOKEN` is accepted as a fallback by
> `scripts/update-remote-indices.ps1`. Define either `GITHUB_AUTH_TOKEN` (preferred) or
> `GITHUB_TOKEN`. Providing both is harmless.

---

## Optional — model provider credentials

Only required when the corresponding provider is actually used by the agent. If a provider
is never selected, its variable may be left unset.

| Variable | Used by | Purpose |
|---|---|---|
| `NVIDIA_NIM_API_KEY` | `.opencode/opencode.jsonc` — NVIDIA NIM provider | API key for the NVIDIA NIM (OpenAI-compatible) provider. |
| `NVIDIA_NIM_BASE_URL` | `.opencode/opencode.jsonc` — NVIDIA NIM provider | Base URL for the NVIDIA NIM provider endpoint. |
| `CLINE_API_KEY` | `.opencode/opencode.jsonc` — Cline provider | API key for the Cline (OpenAI-compatible) provider. |
| `QWENCLOUD_TOKEN_PLAN_API_KEY` | `.opencode/opencode.jsonc` — QwenCloud provider | API key for the QwenCloud (Anthropic-compatible, Alibaba Token Plan) provider. |

### Optional — provider credential fallbacks

The two built-in providers below resolve credentials from an `auth.json` file first and fall
back to these environment variables. Define them only when not using `auth.json`.

| Variable | Used by | Purpose |
|---|---|---|
| `ZAI_CODING_PLAN_OPEN_AI_API_KEY` | `.opencode/opencode.jsonc` — `zai-coding-plan` provider | Fallback API key when `auth.json` is absent. |
| `OPENCODE_GO_API_KEY` | `.opencode/opencode.jsonc` — `opencode-go` provider | Fallback API key when `auth.json` is absent. |

---

## Do NOT set — internal runtime state

The following variable is **set at runtime by the code itself** (the `gh-issue-tracking-init`
skill's `common.ps1`). It is not a secret and must not be pre-defined in the environment;
doing so could interfere with the skill's log-file management.

| Variable | Owner | Notes |
|---|---|---|
| `GHIT_LOG_FILE` | `gh-issue-tracking-init` skill | Carries the active log-file path between dot-sourced operation scripts. Reset automatically each run. |

---

## Quick-start minimum set

For a clone environment that needs only the default MCP tools and the standard GitHub
automation, define these four variables:

```sh
export EXA_API_KEY="..."
export Z_AI_API_KEY="Bearer <api-key>"   # full header value — see Required table
export GITHUB_AUTH_TOKEN="ghp_..."   # or GITHUB_TOKEN
export GITHUB_USERNAME="..."
```

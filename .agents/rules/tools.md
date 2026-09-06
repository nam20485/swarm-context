# Tools

Detailed tool guidance and decision points for this project.

## Sequential-Thinking

Sequential-Thinking (`sequentialthinking`) externalizes reasoning into discrete, numbered thought steps that can build linearly *or* be revised, branched, and extended mid-stream. It is for dynamic, reflective problem-solving — not for generating one-shot answers.

Use it for non-trivial, multi-step problems: planning, root-cause analysis, and problems with unclear scope. Do **not** use it for trivial, single-step tasks where a one-shot answer suffices.

### When to use it

- Problems that benefit from structured reasoning: breaking down complex problems into steps, planning/design with room for revision, analysis that may need course correction, problems whose full scope is not clear initially, multi-step solutions, tasks needing context maintained over many steps, and filtering out irrelevant information.

### How to use it well

- Start with an initial `totalThoughts` estimate, but treat it as adjustable — you can revise it up or down as you progress.
- Let each thought build on the previous ones, but you are not locked into a linear path.
- Generate a hypothesis, then verify it within the chain; repeat until you reach a satisfactory answer.
- Express uncertainty explicitly when present, and ignore information irrelevant to the current step.

### Revision and branching

- **Revise** (`isRevision: true`, `revisesThought: <n>`) when questioning, course-correcting, or changing a previous decision. Feel free to question or revise previous thoughts.
- **Branch** (`branchFromThought: <n>`, `branchId: "<id>"`) to explore an alternative approach or assumption non-linearly while leaving the original line of reasoning intact.

### Adjusting and terminating

- Use `needsMoreThoughts: true` if you reach the planned end but realize more reasoning is required — don't hesitate to add more thoughts even at the "end".
- Only set `nextThoughtNeeded: false` when truly done and a satisfactory answer has been reached; provide a single, ideally correct answer as the final output.
- Control flow with `nextThoughtNeeded` — don't rely on the thought count alone (if `thoughtNumber` exceeds `totalThoughts`, the server auto-bumps `totalThoughts` to match).

## Memory

Memory is a persistent knowledge-graph store (`@modelcontextprotocol/server-memory`) that survives across sessions and chats. Its data model is three primitives:

- **Entities** — typed nodes with a unique `name`, a specific `entityType`, and a list of `observations`.
- **Observations** — discrete string facts attached to an entity. **One fact per observation.**
- **Relations** — directed edges (`from` → `to`) with a `relationType`, always stored in **active voice**.

Use Memory for **durable, reusable context**, not transient scratch state (which belongs in TODO lists/chat). Never store secrets/PII (the store is plaintext). Search before creating to avoid duplicates; keep observations atomic, specific, and active-voiced.

### When to store

- Store durable facts: entity attributes, project/repository structure, decisions **and their rationale**, cross-component relationships, ownership, locations/paths/URLs/IDs, stable conventions.
- Do **not** store secrets, credentials, tokens, or PII — the store is a plaintext local file.
- Do **not** store large blobs, logs, or full file contents — store a reference (path/URL) instead.
- Do **not** dump chat transcripts or transient task progress — keep the graph high-signal.

### Search before create (de-duplicate)

- Before creating any entity, call `search_nodes` (fuzzy match) and/or `open_nodes` (exact name) to find existing matches.
- Prefer adding observations to an existing entity (`add_observations`) over creating a duplicate — `create_entities` silently ignores names that already exist, so a duplicate create loses the new observations.
- Before creating a relation, confirm both endpoints exist; `create_relations` skips exact duplicates automatically.

### Writing good observations and relations

- Make each observation **atomic and self-contained** — it should make sense read in isolation.
- Be **specific and concrete**: include values, IDs, versions, paths, URLs (e.g. `"uses PostgreSQL 16, host db.internal:5432"` beats `"uses a database"`).
- Avoid vague judgements like `"is important"` — state the constraint or reason instead.
- Use **active voice** for `relationType` (`"ServiceA calls ServiceB"`, not `"ServiceB is called by ServiceA"`) and reuse consistent verb phrases across the graph.

### Entity naming and types

- Use **unique, stable entity names** (the name is the identifier; renaming is not supported — delete and recreate).
- Use **specific, consistent `entityType` values** (e.g. `microservice`, `cli-tool`, `adr`, `team`) rather than a generic `thing`.

### Maintenance

- When a fact changes or is contradicted, **delete the stale observation** (`delete_observations`) and add the corrected one.
- Remove obsolete entities (`delete_entities` cascades to their relations) and obsolete edges (`delete_relations`).
- Keep the graph tidy; don't let it bloat with low-value noise.

## Semantic Search (Codebase Indexing)

The `semantic_search` tool (powered by Kilo Code's codebase indexing) finds code by **meaning**, not by exact text. It uses AI embeddings to rank semantic code blocks (functions, classes, methods, markdown sections) against a natural-language query, returning ranked matches with file paths and line ranges.

**Prerequisite:** Codebase indexing is enabled and available for this project. The tool errors only if the index is disabled or empty; otherwise assume it is ready.

**When to use `semantic_search` — prefer it as the first probe when you:**

- Are exploring an **unfamiliar** code area before you know exact identifiers.
- Are looking for a feature, behavior, or **intent** ("authentication logic", "database connection setup", "error handling patterns", "API endpoint definitions", "rate limiting").
- Want to locate **conceptually related** implementations or similar code patterns spread across the codebase.
- Need to **narrow a large codebase** before following up with `Grep` / `Glob` / `Read`.

**When NOT to use it — pick the specialized tool instead:**

- Exact symbol, regex, or keyword lookups → `Grep`.
- Finding files by name or extension (e.g. `**/*.ts`, `*.config.js`) → `Glob`.
- Reading a file whose path you already know → `Read`.
- Exploring files **outside** the current workspace → `Grep` / `Glob` / `Read` (`semantic_search` is workspace-scoped).

**How to query:**

- Write the query in **natural language, in English** (e.g. "where are user sessions validated before API access?").
- Prefer **specific, descriptive** phrasing over vague nouns. "Redis retry/backoff handling" beats "redis".
- To restrict results to a subdirectory, pass the `path` argument (relative to the workspace root). Leave it empty for a whole-workspace search.
- After getting ranked matches, follow up with `Read` (to inspect the returned line ranges) or `Grep` (to enumerate exact occurrences of an identifier you discovered).

**Tuning (optional, set in `indexing` under `kilo.jsonc`):**

- `searchMaxResults` (default `50`) — lower for faster, more focused results; raise for broader context.
- `searchMinScore` (default `0.4`) — raise to require closer matches; lower to surface tangentially related code.

Full guide: [Codebase Indexing](https://github.com/Kilo-Org/kilocode/blob/main/packages/kilo-docs/pages/customize/context/codebase-indexing.md).

## Web & Repository Research (Z.AI MCP)

These three **remote** Z.AI MCP servers (configured in [`.opencode/opencode.jsonc`](../../.opencode/opencode.jsonc)) authenticate via the `Authorization: {env:Z_AI_API_KEY}` header. Z.AI requires the `Bearer <api-key>` header format and opencode substitutes the env var verbatim as the full header value, so **`Z_AI_API_KEY` must be the full header value, `Bearer <api-key>`**. The servers require no local install; use them for reliable, structured external information retrieval instead of ad-hoc fetching.

### `web-search-prime` — web search

Tool: **`webSearchPrime`** — searches the web; returns page titles, URLs, summaries, site names, and site icons.

Features:

- Comprehensive web search to retrieve the latest web information and resources.
- Real-time updated information: news, stock prices, weather, and more.
- HTTP-based remote MCP service — no local installation required.

Key params: `content_size` (`medium` default, `high` for comprehensive), `location` (`cn` / `us`), `search_domain_filter` (whitelist a domain), `search_recency_filter` (`oneDay` / `oneWeek` / `oneMonth` / `oneYear` / `noLimit`). Keep queries ≤ 70 chars.

Example scenarios:

- Best-practice surveys, competitive analysis, and dependency/API research.
- Factual questions needing current external info (e.g. "find best practices for Python asynchronous programming").

### `web-reader` — URL reader

Tool: **`webReader`** — fetches a URL and converts it to large-model-friendly input (markdown / text / html). Prefer this over generic `webfetch` when available.

Features:

- **Web Content Reading** — fetch the complete content of any webpage, including text and links.
- **Structured Data** — extract structured data such as title, main body, and metadata.
- **Remote Service** — HTTP-based remote MCP service, no local installation required.

Example scenarios:

- **API documentation reading and summarization** — fetch official docs pages (titles, body, examples, release notes) and distill key takeaways to speed integration.
- **Open-source project page parsing** — parse project sites and repository pages (README, release notes, usage guides) into core info and link lists for evaluation.
- **Technical article knowledge extraction** — pull steps, commands, and caveats out of blogs/tutorials/guides into actionable developer notes and task lists.
- **Bug resolution from reference documentation** — read publicly documented fixes on a specified page and apply them as the reference solution.
- **Knowledge-base construction and synchronization** — convert pages to structured data and follow in-page links for incremental synchronization.

### `zread` — public GitHub repository reader

Reads **public** GitHub repositories without cloning (powered by zread.ai) — open-source repository Q&A: documentation, code structure, and file content.

Features:

- Search documentation, code, and comments in GitHub repositories.
- Get the directory structure and file list of a repository to quickly master project layout.
- Read the complete code content of specified files to deeply analyze implementation details.

Tools:

- **`search_doc`** — search a repository's knowledge documentation: repo knowledge, news, recent issues, PRs, and contributors.
- **`get_repo_structure`** — directory structure and file list; understand module splitting and organization.
- **`read_file`** — complete contents of a specified file; analyze implementation details in depth.

Constraints: requires `owner/repo` names; only **public** repositories are supported.

Example scenarios:

- **Learn a library fast** — `search_doc` + `get_repo_structure` for core concepts, installation steps, and code organization before writing code against it.
- **Mine issue/commit history** — find solutions or fix records for a problem you are hitting ("has anyone hit this before?").
- **Secondary development and debugging** — `read_file` the core files to analyze implementation logic before extending or fixing.
- **Pre-adoption dependency evaluation** — activity, code quality, and maintenance status before introducing a new dependency.

### Decision points

- Need current facts from the open web → `webSearchPrime`, then `webReader` to drill into a specific result.
- Need to understand an open-source repo → `zread` first (`get_repo_structure` + `search_doc`), then `read_file` for implementation details.
- For broad, multi-source surveys, delegate to the `researcher` subagent; use these tools directly for quick, single-shot lookups.

Sources: Z.AI DevPack docs — [Web Search](https://docs.z.ai/devpack/mcp/search-mcp-server) · [Web Reader](https://docs.z.ai/devpack/mcp/reader-mcp-server) · [Zread](https://docs.z.ai/devpack/mcp/zread-mcp-server) (overview → Example Scenarios sections).

## Exa Search (MCP)

The **remote** Exa MCP server authenticates via `exaApiKey={env:EXA_API_KEY}` and requires no local install. Use it as a complement to Z.AI when its neural search, code-context, or crawling fits better.

- **`web_search_exa`** — Keyword/neural web search. Fallback when Z.AI `webSearchPrime` is rate-limited.
- **`web_search_advanced_exa`** — Filtered search (date, domain, text-match, count). Scoped queries.
- **`web_fetch_exa`** — Fetch a URL to clean markdown/text. Alternative to Z.AI `webReader`.
- **`get_code_context_exa`** — Code context (functions, types, usage) for "how is X used?" before `zread` for full files.
- **`crawling_exa`** — Crawl multiple pages of a site; collect a doc subsite in one call.

Prefer Z.AI `webSearchPrime`/`webReader` as the default for single-shot lookups; reach for Exa when its neural search, code-context, or crawling fits better.

## Scratch Workspaces (per-run temp state)

Per-run scratch — composed drivers, rendered bodies, trace logs, throwaway diagnostics — lives namespaced **by repo slug** under `/tmp/kilo/<repo-slug>/`, **not** loose in a flat `/tmp/kilo/`. This isolates one repo's run from another's (a stale driver on disk hardcodes a specific repo + node set, so silent cross-run mis-targeting of a GitHub-mutating run is the risk) and makes cleanup a single `rm -rf /tmp/kilo/<repo-slug>`.

Standard layout:

```text
/tmp/kilo/<repo-slug>/
  ├─ driver.<ext>   # composed orchestration script for this run
  ├─ bodies/        # rendered file bodies passed to tools (e.g. issue -BodyFile)
  ├─ logs/          # trace / run logs
  └─ diag/          # throwaway diagnostic / experiment scripts
```

- **Root is `/tmp/kilo/`** — the bash tool's pre-approved external-work directory. Scratch goes **under** it (not directly under `/tmp/<slug>/`), so there is no external-dir approval prompt and no collision with the OS `/tmp`.
- **Create on demand** (`mkdir -p` / `New-Item -ItemType Directory -Force`). Never assume a previous run's scratch belongs to the current one — before reusing anything under `/tmp/kilo/`, confirm the slug matches the current repo.
- **Durable artifacts are not scratch.** Trace logs worth keeping, fix write-ups, and decision records go under `docs/plans/`, not `/tmp/kilo/`.

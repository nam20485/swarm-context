# Qwen Code Documentation Lookup

Rule: whenever a task involves **Qwen Code** — questions about its usage, features, configuration, setup, or troubleshooting — answer from the official Qwen Code documentation, not from memory.

Machine-readable access points:

- **Documentation index** — a markdown `llms.txt` listing every docs page (user guide, IDE integrations, features, configuration, developer guide, support) with title and one-line description: `https://qwenlm.github.io/qwen-code-docs/llms.txt`. It is an index only (links + descriptions, ~4.6 KB); there is **no** `llms-full.txt` full-content dump.
- **Individual pages** — raw Markdown from the upstream repo's `docs/` directory (`QwenLM/qwen-code`): `https://raw.githubusercontent.com/QwenLM/qwen-code/main/docs/<path>.md`. Derive `<path>` from the site URL by stripping the `/en/` prefix and the trailing slash, then appending `.md`; e.g. page `https://qwenlm.github.io/qwen-code-docs/en/users/features/mcp/` → `https://raw.githubusercontent.com/QwenLM/qwen-code/main/docs/users/features/mcp.md`.

Decision points:

- Broad or unknown-scope question → fetch `llms.txt` and locate the relevant page.
- Known page path (or one discovered from `llms.txt`) → fetch just that page's raw Markdown to save context.
- Raw path returns 404 (generated pages such as the blog index) → fall back to fetching the rendered site page.

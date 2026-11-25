---
paths:
  - ".github/workflows/*.yml"
  - ".github/tests/claude-action-permissions/**"
---

# The `additional_permissions` trap

`anthropics/claude-code-action`'s `additional_permissions:` input takes a **GitHub permissions map** — `actions: read` and nothing else. A Claude **tool list** written there is silently inert: no `allowedTools` reaches the SDK, the action's default policy denies the writes, and **the SDK exits 0 on a permission denial**, so the run goes green having done nothing. Three workflows here had it; `reusable-claude.yml` always had it right and is the canonical shape:

- tools go in an `allowed_tools` input (comma-separated), composed into `claude_args` as `--allowedTools "..."` — a **separate input from `claude_args`** on purpose, so a caller overriding `--model`/`--max-turns` cannot silently drop the tool grant. `reusable-changelog-review.yml` is the deliberate exception: its list is pinned inline and not caller-tunable, because the *exclusions* (`WebFetch`/`WebSearch`) are part of its prompt's contract that the pre-sliced excerpt is the only input
- `additional_allowed_tools` appends caller extras; `additional_permissions` is the permissions map only
- `--allowedTools` is **additive** over the action's defaults, so listing tools widens rather than restricts
- naming `TodoWrite` is a real grant, not decoration — since 2.1.233 the todo/task tools are off by default on current models and listing one is the session-wide opt-in
- diagnose from the job log's `SDK options:` block: `allowedTools` absent = broken

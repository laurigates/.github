---
paths:
  - ".github/workflows/reusable-sync-ai-rules.yml"
  - ".github/tests/sync-ai-rules-targets/**"
  - ".github/tests/rulesync-ignore/**"
---

# `reusable-sync-ai-rules.yml`

- **`reusable-sync-ai-rules.yml`** — syncs AI coding rules from this `.github` repo into calling repos via rulesync, creating a PR with tool-specific configs for Claude Code, Copilot, Antigravity CLI, and Cursor. Pass `app-id` + `APP_PRIVATE_KEY` to open that PR with an App token: `GITHUB_TOKEN` is refused outright in a repo where Actions may not create pull requests (GitHub's default), and a PR it does open triggers no CI. Both rulesync steps run one exact version (`npx rulesync@40.2.0`), never `@latest`: rulesync ships a major almost daily, and every caller runs this workflow at `@main` (`tool-pins`; see `.claude/rules/rulesync.md`)

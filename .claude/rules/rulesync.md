# Rulesync (v9+) — Source Layout & CLI Gotchas

This repo is the rules **source** for `reusable-sync-ai-rules.yml`: consumer
repos run `rulesync fetch laurigates/.github --path .rulesync` and generate
tool-specific configs from `.rulesync/rules/*.md` + the root `rulesync.jsonc`.

The same files are the single source for the local workspace copy:
`just laurigates rules-generate` in `~/repos` (repos-claude-config) generates
the Claude output into `~/repos/laurigates/.claude/rules/`, and
`just laurigates rules-drift` reports when the two differ. Edit facts here,
never in the workspace copy.

Facts proven empirically while fixing #10 (evidence trail in PR #31), all
reproduced on rulesync 9.1.0:

- **Bare `rulesync fetch <repo>` reads `rules/` at the source repo ROOT, not
  `.rulesync/`.** Without `--path .rulesync` it 404s and reports "no files"
  even when `.rulesync/rules/` is fully populated. Keep `--path .rulesync` in
  the workflow's fetch step.
- **v9.0.0 removed the `geminicli` target and the `baseDirs` config option,
  but only `geminicli` fails.** `geminicli` in `rulesync.jsonc` targets or in
  rule frontmatter makes `generate` hard-fail schema validation (exit 1); use
  `antigravity-cli` / `antigravity-ide` instead. `baseDirs` is silently
  ignored, not rejected: with `"baseDirs": ["sub"]` in `rulesync.jsonc`, or
  `baseDirs` in rule frontmatter, both 9.1.0 and 40.2.0 exit 0 and write every
  output at the root, none under `sub/`, and neither version's `dist/`
  mentions `baseDirs` (re-checked 2026-10-22). Omit it: it does nothing, while
  a reader would expect it to scope the output.
- **Config-less `generate` defaults to the `agentsmd` target only** and emits
  zero files for these rules. Consumer repos never receive `rulesync.jsonc`
  (fetch pulls only the `rules` + `ignore` features), so the workflow's
  generate step must pass explicit `--targets ... --features rules,ignore`.
- **Never run `rulesync generate` at this repo's root** — this repo's real
  `CLAUDE.md` is a generate target and would be overwritten. Test in a
  scratch dir with `rulesync.jsonc` + `.rulesync/` copied in; `just
  rules-check` does exactly that with the pinned version (lint.yml's step).

rulesync is pinned to one exact version everywhere (`rulesync@X.Y.Z` in
`lint.yml` and `reusable-sync-ai-rules.yml`). It ships a major almost daily
and consumers run the sync workflow at `@main`, so `@latest` changes their
output with no change here. Bump every site together; the `tool-pins` test
fails until they agree.

When editing `.rulesync/rules/*.md`, keep frontmatter valid per upstream's
RulesyncRuleFrontmatterSchema (`root`/`targets`/`description`/`globs`) and run
`just leak-check` (no upstream-org identifiers may land in this repo's
sources).

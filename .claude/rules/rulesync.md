# Rulesync (v9+) — Source Layout & CLI Gotchas

This repo is the rules **source** for `reusable-sync-ai-rules.yml`: consumer
repos run `rulesync fetch laurigates/.github --path .rulesync` and generate
tool-specific configs from `.rulesync/rules/*.md` + the root `rulesync.jsonc`.

Facts proven empirically while fixing #10 (evidence trail in PR #31), all
reproduced on rulesync 9.1.0:

- **Bare `rulesync fetch <repo>` reads `rules/` at the source repo ROOT, not
  `.rulesync/`.** Without `--path .rulesync` it 404s and reports "no files"
  even when `.rulesync/rules/` is fully populated. Keep `--path .rulesync` in
  the workflow's fetch step.
- **v9.0.0 removed the `geminicli` target and the `baseDirs` config option.**
  Either one in `rulesync.jsonc` or rule frontmatter makes `generate`
  hard-fail schema validation. Use `antigravity-cli` / `antigravity-ide`
  instead of `geminicli`; omit `baseDirs`.
- **Config-less `generate` defaults to the `agentsmd` target only** and emits
  zero files for these rules. Consumer repos never receive `rulesync.jsonc`
  (fetch pulls only the `rules` + `ignore` features), so the workflow's
  generate step must pass explicit `--targets ... --features rules,ignore`.
- **Never run `rulesync generate` at this repo's root** — this repo's real
  `CLAUDE.md` is a generate target and would be overwritten. Test in a
  scratch dir with `rulesync.jsonc` + `.rulesync/` copied in.

When editing `.rulesync/rules/*.md`, keep frontmatter valid per upstream's
RulesyncRuleFrontmatterSchema (`root`/`targets`/`description`/`globs`) and run
`just leak-check` (no upstream-org identifiers may land in this repo's
sources).

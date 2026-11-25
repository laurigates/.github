---
paths:
  - ".github/workflows/reusable-enforce-conventional-commits.yml"
  - ".github/workflows/reusable-release-please.yml"
  - ".github/actions/squash-message-check/**"
  - ".github/tests/squash-message-check/**"
---

# `reusable-enforce-conventional-commits.yml`

- **`reusable-enforce-conventional-commits.yml`** — auto-fixes PR titles to conventional commits format with 80+ verb-to-type mappings. Opt-in `squash-message-check: off|warn|error` (default `off`), only for repos with `squash_merge_commit_message = PR_BODY`, adds a second job that parses the squash commit with release-please's own parser before merge. Three things not to re-derive:
  - **The title comes from the API, not the event payload.** The job runs `needs: fix-pr-title` (with `!cancelled()` in its `if:`, so a title the fixer cannot repair does not skip the body check) on ubuntu-slim and reads title and body with `gh api repos/$REPO/pulls/$N`: the fixer's `GITHUB_TOKEN` edit starts no new run, so the payload can still hold the old title. `jq -c` keeps the JSON on one line, so no title or body can forge a `GITHUB_OUTPUT` line
  - **The check lives in `.github/actions/squash-message-check`, referenced fully qualified** (`laurigates/.github/.github/actions/squash-message-check@main`), like `scan-image`. The action npm-installs `@conventional-commits/parser` alone into `$RUNNER_TEMP` and runs `check.mjs`, which rebuilds the squash message with GitHub's wrap model: `<title> (#N)`, then the body hard-wrapped at 72 code points, lines under a column-0 fence left alone, wrapped lines losing their indentation. The wrap, not the description as written, is what puts a mid-sentence call such as `name(` at a line start, where the parser reads a footer and throws. The parser stops at its first error, so when the title alone does not parse `check.mjs` parses the description again under a placeholder title (same line numbers, since the subject is one line); the job passes `title-reported: needs.fix-pr-title.result == 'failure'`, which turns the title error into a notice instead of a second failure
  - **`PARSER_VERSION` follows the release-please-action pin.** `googleapis/release-please-action@v4.4.1` in `reusable-release-please.yml` resolves release-please 17.3.0, which bundles parser 0.4.1; bump them together

  `.github/tests/squash-message-check/run.sh` runs the action's shipped install and parse steps against fixture bodies, plus the job's validate and PR-read steps against a stub `gh`, and fails when the two pins drift. It needs node, npm and npm registry access

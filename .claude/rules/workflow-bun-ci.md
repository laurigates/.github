---
paths:
  - ".github/workflows/reusable-bun-ci.yml"
  - ".github/tests/bun-ci/**"
  - "docs/bun-ci.md"
---

# `reusable-bun-ci.yml`

- **`reusable-bun-ci.yml`** — pull-request gate for bun/TypeScript repos: one `ubuntu-latest` job (setup-bun downloads Bun, so not slim) that installs from `bun.lock` and runs the caller's own typecheck (opt-in), test and build commands, with an optional `coverage` artifact; no secrets, `contents: read`. Commands reach `eval` through `env:`, never `${{ inputs.* }}` in a `run:` body. Concurrency is job-level with a `bun-ci-` prefix, because a called workflow sees the caller's `github.workflow` and an equal group cancels the caller. `.github/tests/bun-ci/run.sh` (`just bun-ci`) runs the extracted steps against stub `bun`/`bunx`/`node`, checks every input is in README's `## Bun CI Workflow Inputs` table with its declared default, and holds a per-file baseline of `${{ inputs.* }}` in run bodies across *every* workflow: lower a count when a file is fixed, never raise one

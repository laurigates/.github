# Bun CI

## Bun CI Workflow Inputs

`reusable-bun-ci.yml` is the pull-request gate for bun/TypeScript repos: install from `bun.lock`, then run the repository's own typecheck, test and build commands in one job. It takes no secrets and needs only `contents: read`.

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `install-command` | string | `bun install --frozen-lockfile` | Dependency install command. Bun does not enable `--frozen-lockfile` on its own in CI |
| `typecheck-command` | string | `''` | Type-check command, run after install (empty string to skip; opt-in) |
| `test-command` | string | `bun run test` | Test command (empty string to skip) |
| `build-command` | string | `bun run build` | Build command (empty string to skip) |
| `coverage` | boolean | `false` | Upload `<working-directory>/coverage/` as the `coverage` artifact (30-day retention; fails if the directory is empty) |
| `bun-version` | string | `''` | Bun version for `oven-sh/setup-bun`. Empty reads `packageManager`/`engines.bun` from the repository-root `package.json`, then falls back to latest |
| `node-version` | string | `''` | Node.js version for setup-node (empty string to skip Node setup) |
| `cache-dependencies` | boolean | `true` | Cache `~/.bun/install/cache` keyed on `<working-directory>/bun.lock` |
| `working-directory` | string | `.` | Directory containing `package.json` and `bun.lock` |
| `runner` | string | `ubuntu-latest` | Runner label |
| `timeout-minutes` | number | `15` | Job timeout in minutes |

Commands are read from `env:` and run through `eval`, so shell operators work — a pre-install step chains onto `install-command` (`bun install --frozen-lockfile && bun run db:generate`). `coverage: true` does not change the test command; point `test-command` at the script that writes `coverage/` (e.g. `bun run test:coverage`). Codecov upload stays in the caller.

**The build script is not necessarily the type gate.** Bundlers such as esbuild (WXT, Vite) strip type annotations without checking them, and plain `tsc --noEmit` can be red on arrival where a framework supplies ambient types through its own tsconfig (the first adopting WXT extension reported 201 errors, 149 of them chrome-namespace). `build-command` therefore defaults to the repo's own `bun run build`, and `typecheck-command` is opt-in. Set it to whatever the repo treats as its type gate.

**A production build may hard-fail without secrets.** A PR gate compiles the code; it does not assert that secrets exist — secret presence belongs in the release workflow. If the production build throws on missing credentials, build in development mode instead (`bunx wxt build --mode development`).

`bun-version` should be set explicitly for subdirectory projects: setup-bun's `package.json` fallback reads the repository root, not `working-directory`. Concurrency is set at job level with a `bun-ci-` group prefix; do not give the caller a concurrency group starting with `bun-ci-`, because a called workflow sees the caller's name in `github.workflow` and equal groups cancel the caller.

The default runner is `ubuntu-latest`, not `ubuntu-slim`: slim has no tool cache, so setup-bun (and setup-node) download the runtime on every run, and a project's own tests and build may need more than one CPU or anything slim lacks.

```yaml
on:
  pull_request:
    branches: [main]

permissions:
  contents: read

jobs:
  bun-ci:
    uses: laurigates/.github/.github/workflows/reusable-bun-ci.yml@main
    with:
      test-command: bun run test:coverage
      typecheck-command: bun run compile:gate
      build-command: bunx wxt build --mode development
      coverage: true
```

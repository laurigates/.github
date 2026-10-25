# laurigates/.github

Default community health files and reusable GitHub Actions workflows for [@laurigates](https://github.com/laurigates) repositories.

## What's here

| Path | Purpose |
|------|---------|
| `profile/README.md` | Profile shown on [github.com/laurigates](https://github.com/laurigates) |
| `CODE_OF_CONDUCT.md` | Default code of conduct for all repos |
| `CONTRIBUTING.md` | Default contribution guidelines for all repos |
| `SECURITY.md` | Security vulnerability reporting policy |
| `SUPPORT.md` | Where to get help |
| `.github/ISSUE_TEMPLATE/` | Default issue templates for all repos |
| `.github/PULL_REQUEST_TEMPLATE.md` | Default PR template for all repos |
| `.github/workflows/reusable-*.yml` | Reusable workflows callable from any repo |

## Reusable Workflows

Call these from any repo using `uses: laurigates/.github/.github/workflows/<name>.yml@main`.

### Infrastructure

| Workflow | Description |
|----------|-------------|
| `reusable-container-build.yml` | PR phase: build and push `:next-{version}` pre-release image to GHCR |
| `reusable-container-release.yml` | Release phase: promote pre-built image to semver tags (or fallback rebuild) + Trivy scan |
| `reusable-release-please.yml` | Automated releases via release-please (+ missed-release guard) |
| `reusable-auto-merge-image-updater.yml` | Auto-merge ArgoCD Image Updater PRs |
| `reusable-fix-release-conflicts.yml` | Auto-resolve release-please merge conflicts |
| `reusable-claude.yml` | Claude Code @-mention support in issues and PRs |
| `reusable-changelog-review.yml` | Weekly Claude Code changelog triage: gate on new upstream versions, open a tracking issue + version-ratchet PR (caller supplies the analyzer script) |

### Build & Test

| Workflow | Description |
|----------|-------------|
| `reusable-bun-ci.yml` | Pull-request gate for bun/TypeScript repos: `bun install --frozen-lockfile`, then the repo's own typecheck (opt-in), test and build commands; optional coverage artifact; no secrets. Inputs: [Bun CI Workflow Inputs](#bun-ci-workflow-inputs) |

### Security (Claude-powered)

| Workflow | Description |
|----------|-------------|
| `reusable-security-secrets.yml` | Detect leaked secrets and credentials |
| `reusable-security-deps.yml` | Dependency vulnerability audit |
| `reusable-security-owasp.yml` | OWASP Top 10 static analysis |

### Quality (Claude-powered)

| Workflow | Description |
|----------|-------------|
| `reusable-quality-code-smell.yml` | Code smell and anti-pattern detection |
| `reusable-quality-async.yml` | Async pattern validation |
| `reusable-quality-typescript.yml` | TypeScript strictness analysis |

### Accessibility (Claude-powered)

| Workflow | Description |
|----------|-------------|
| `reusable-a11y-aria.yml` | ARIA pattern correctness |
| `reusable-a11y-wcag.yml` | WCAG 2.1 compliance check |

## Usage Example

```yaml
# In your repo's .github/workflows/container-build.yml
name: Build and release container

on:
  push:
    tags: ['my-app-v*.*.*']
  pull_request:
    branches: [main]

jobs:
  build:
    if: startsWith(github.head_ref, 'release-please--branches--main')
    uses: laurigates/.github/.github/workflows/reusable-container-build.yml@main
    with:
      image-name: laurigates/my-app

  release:
    if: github.event_name == 'push'
    uses: laurigates/.github/.github/workflows/reusable-container-release.yml@main
    with:
      image-name: laurigates/my-app
      tag-prefix: my-app-v

  security:
    if: github.event_name == 'pull_request'
    uses: laurigates/.github/.github/workflows/reusable-security-owasp.yml@main
    secrets:
      CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

`tag-prefix` must prefix every release tag the caller triggers on: the release workflow strips it and derives all image tags from what remains (`my-app-v1.2.3` → `1.2.3`, `1.2`, `1`, `latest`; a pre-release such as `my-app-v1.2.3-rc.1` → `1.2.3-rc.1` only). A tag the prefix does not match fails the run with an `::error::`.

## Missed-Release Guard

release-please can discard every commit in a push and still exit green. Its
conventional-commit parser throws on some commit bodies — and repos with
`squash_merge_commit_message = PR_BODY` get the PR description as the commit
body, so a fenced code block in a PR description is enough to trigger it. The
run logs `Considering: 0 commits`, no release PR appears, and the outcome is
indistinguishable from "nothing releasable landed".

`reusable-release-please.yml` re-checks the pushed range whenever release-please
reports neither a release PR nor a release. If the range still contains
conventional commits that should have released, it annotates the run and writes
the offending subjects to the job summary.

```yaml
uses: laurigates/.github/.github/workflows/reusable-release-please.yml@main
with:
  missed-release-check: error   # warn (default) | error | off
  releasable-types: feat,fix,perf,revert
```

The guard also exposes a `missed_release` output for callers that want to fan
out (notify, open an issue) instead of failing the job.

Two caveats: the guard only fires when release-please produced *nothing*, so a
run where one commit parsed and another was dropped still under-releases
silently; and the durable fix for the root cause is repo settings, not CI —
switch release-please-managed repos to
`squash_merge_commit_message = COMMIT_MESSAGES` so the squash body is the
authored commit message rather than the PR description.

## Finding the Release PR

A release PR is opened by a bot and mentions nobody, so it shows up in none of
GitHub's dashboard or mobile feeds — not `author:@me`, not `review-requested:@me`,
not even `involves:@me`. `reusable-release-please.yml` assigns it instead, which
puts it in the **Assigned** tab and under `is:open is:pr assignee:@me`.

This is on by default and assigns the repository owner; no caller change is
needed. To assign someone else, or several people:

```yaml
uses: laurigates/.github/.github/workflows/reusable-release-please.yml@main
with:
  pr-assignees: alice,bob   # default: the repository owner; 'none' disables
```

`@me` is deliberately not accepted — `gh` resolves it to the token owner, which
is the GitHub App bot whenever `app-id` is set. Use literal usernames.

The step assigns whatever PR release-please created or updated in the run, and
falls back to any open `release-please--branches--*` PR when the run touched
none, so an already-open release PR gets picked up too. A failed assignment
(unknown username, or one without repository access) warns rather than failing
the release.

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

## Container Signing

Release images are signed with [Sigstore cosign](https://docs.sigstore.dev/) using keyless mode (OIDC identity from GitHub Actions). Signatures are recorded in the [Rekor](https://docs.sigstore.dev/logging/overview/) public transparency log.

### Verifying signatures

```bash
cosign verify \
  --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
  --certificate-identity-regexp='https://github.com/laurigates/' \
  ghcr.io/laurigates/my-app:1.2.3
```

### Opting out

Pass `enable-signing: false` to the release workflow:

```yaml
uses: laurigates/.github/.github/workflows/reusable-container-release.yml@main
with:
  image-name: laurigates/my-app
  tag-prefix: my-app-v
  enable-signing: false
```

## Community Health Files

Files at the root of this repo serve as defaults for all [@laurigates](https://github.com/laurigates) repositories. Individual repos can override any of them by providing their own copy.

Files that **cannot** be defaults (must be per-repo): `LICENSE`

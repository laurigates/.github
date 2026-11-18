# Reusable Workflows

Call these from any repo using `uses: laurigates/.github/.github/workflows/<name>.yml@main`.
Each workflow file under [`.github/workflows/`](../.github/workflows/) declares
its inputs and secrets under `on.workflow_call`.

### Infrastructure

| Workflow | Description |
|----------|-------------|
| `reusable-container-build.yml` | PR phase: build and push `:next-{version}` pre-release image to GHCR |
| `reusable-container-release.yml` | Release phase: promote pre-built image to semver tags (or fallback rebuild) + Trivy scan |
| `reusable-release-please.yml` | Automated releases via release-please (+ missed-release guard) |
| `reusable-auto-merge-image-updater.yml` | Auto-merge ArgoCD Image Updater PRs |
| `reusable-fix-release-conflicts.yml` | Auto-resolve release-please merge conflicts |
| `reusable-clear-autorelease-labels.yml` | Manual escape hatch: strip a stale `autorelease: pending` label from closed PRs when a failed release step keeps release-please retrying it |
| `reusable-npm-publish.yml` | Publish an npm package with OIDC trusted publishing (no `NPM_TOKEN`); the caller grants `id-token: write` |
| `reusable-sync-ai-rules.yml` | Sync the AI coding rules in this repo's `.rulesync/` into the caller as a PR, via rulesync |
| `reusable-changelog-review.yml` | Weekly Claude Code changelog triage: gate on new upstream versions, open a tracking issue + version-ratchet PR (caller supplies the analyzer script) |
| `reusable-renovate.yml` | Renovate runner on a GitHub App token; the optional `ANTHROPIC_API_KEY` secret adds an `api.anthropic.com` host rule for the custom datasource in this repo's `renovate.json` that tracks pinned Claude model IDs |

### Build & Test

| Workflow | Description |
|----------|-------------|
| `reusable-bun-ci.yml` | Pull-request gate for bun/TypeScript repos: `bun install --frozen-lockfile`, then the repo's own typecheck (opt-in), test and build commands; optional coverage artifact; no secrets. Inputs: [bun-ci.md](bun-ci.md) |

### Pull requests and issues

These change PRs or issues on their own, so a contributor may see their effect
without having called anything.

| Workflow | Description |
|----------|-------------|
| `reusable-enforce-conventional-commits.yml` | Rewrites a PR title into conventional-commit form; optional squash-message parse check ([releases.md](releases.md#squash-commit-parse-check)) |
| `reusable-merge-method.yml` | Posts a `merge-method` check naming the merge button to press and applies a `merge:rebase` / `merge:squash` label ([releases.md](releases.md#merge-method)) |
| `reusable-issue-labels.yml` | Applies type and routing labels from the repo's taxonomy, clears `blocked`, audits label gaps; no model ([issue-labels.md](issue-labels.md)) |
| `reusable-auto-resolve-conflicts.yml` | On each push to the base, merges the base into every conflicting PR and has Claude resolve the conflicts |
| `reusable-auto-fix.yml` | Analyzes a failed CI run and either pushes a fix or opens an issue, with loop protection |

### Review and mentions

| Workflow | Description |
|----------|-------------|
| `reusable-claude.yml` | Claude Code @-mention support in issues and PRs |
| `reusable-claude-review.yml` | Claude Code review of each PR; skips release-please PRs and bot actors by default |
| `reusable-opencode.yml` | `/opencode` (or `/oc`) mentions in issue and PR review comments |
| `reusable-opencode-review.yml` | Review of each PR with an OpenCode model; needs `OPENCODE_API_KEY` |

### Security (Claude-powered)

| Workflow | Description |
|----------|-------------|
| `reusable-security-secrets.yml` | Detect leaked secrets and credentials |
| `reusable-security-owasp.yml` | OWASP Top 10 static analysis |

### Security (no model)

| Workflow | Description |
|----------|-------------|
| `reusable-security-deps.yml` | Dependency vulnerability audit with osv-scanner: each advisory group and its CVSS score in the job summary and as annotations; outputs `vulnerabilities` and `critical` (CVSS 7.0 or higher); `fail-on-high` fails the run on a critical one. Needs no secret |

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

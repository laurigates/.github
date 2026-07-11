# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This is the **laurigates/.github** repository — a special GitHub repo that provides default community health files and reusable GitHub Actions workflows for all [@laurigates](https://github.com/laurigates) repositories. It contains no application code, build system, or tests.

## Repository Structure

- **Root files** (`CODE_OF_CONDUCT.md`, `CONTRIBUTING.md`, `SECURITY.md`, `SUPPORT.md`) — default community health files inherited by all laurigates repos unless overridden
- **`profile/README.md`** — GitHub profile page content
- **`.github/ISSUE_TEMPLATE/`** — default issue templates (bug report, feature request)
- **`.github/PULL_REQUEST_TEMPLATE.md`** — default PR template
- **`.github/workflows/reusable-*.yml`** — reusable workflows (the main deliverable of this repo)

## Workflow Architecture

All workflows are **reusable** (`workflow_call`) and called from other repos via:
```yaml
uses: laurigates/.github/.github/workflows/reusable-<name>.yml@main
```

### Container Build/Release (build-once/promote pattern)

The container workflows implement a two-phase pattern:

1. **`reusable-container-build.yml`** (PR phase) — builds and pushes a `:next-{version}` pre-release image to GHCR during the release-please PR
2. **`reusable-container-release.yml`** (tag phase) — promotes the pre-built image via manifest retag (fast path) or falls back to full rebuild. Includes Trivy scanning and optional cosign keyless signing via Sigstore

The version is extracted from the version file (default: `package.json`) during build, and from the git tag (stripping `tag-prefix`) during release.

### Release Automation

- **`reusable-release-please.yml`** — wraps `googleapis/release-please-action`, requires a PAT (`MY_RELEASE_PLEASE_TOKEN`) since GITHUB_TOKEN can't trigger downstream workflows
- **`reusable-fix-release-conflicts.yml`** — detects conflicted release-please PRs, closes them, deletes the branch, and retriggers release-please to recreate cleanly
- **`reusable-clear-autorelease-labels.yml`** — manual escape hatch (`workflow_dispatch` caller) that strips a stale `autorelease: pending` label from closed PRs. When the release/tag step fails, the merged release PR keeps the `pending` label and every subsequent run re-attempts the same failed release; clearing it lets release-please move on. Supports a `dry_run` input
- **`reusable-auto-merge-image-updater.yml`** — creates, approves, and auto-merges ArgoCD Image Updater PRs in a single job (workaround for GITHUB_TOKEN anti-recursion)

### Claude-Powered Workflows

- **`reusable-claude.yml`** — enables `@claude` mentions in issues and PRs. Supports configurable runner, max turns, and system prompt for CI turn budget awareness. Posts continuation comments on max-turns exhaustion
- **`reusable-claude-review.yml`** — automated PR review using Claude Code. Skips release-please PRs and bot actors by default
- **`reusable-auto-fix.yml`** — analyzes failed CI workflows and either auto-fixes (commit + push) or opens a GitHub issue. Includes flood guards and recent-fix detection to prevent loops
- **`reusable-enforce-conventional-commits.yml`** — auto-fixes PR titles to conventional commits format with 80+ verb-to-type mappings
- **`reusable-changelog-review.yml`** — scheduled upstream-changelog triage (Claude Code's changelog by default). Two-job shape: a pure-bash pre-check gate (version compare against a tracking JSON, skip-if-existing-open-issue idempotency, excerpt slicing, caller-supplied analyzer script) followed by one opus triage run that opens a single tracking issue and a single JSON-ratchet PR. The schedule lives in the caller (`workflow_call` cannot carry one); the repo-specific keyword→file mapping stays in the calling repo via the required `analyzer-script` input. Model/effort default to opus/medium via inputs

#### Claude-Powered Analysis Workflows

Security, quality, and accessibility workflows use `anthropics/claude-code-action@v1`. Each exposes `max-turns` (default 50) and `model` inputs — opus for deep-reasoning jobs, sonnet for the more mechanical ones:
- **Security**: `reusable-security-{secrets,deps}.yml` (sonnet), `reusable-security-owasp.yml` (opus)
- **Quality**: `reusable-quality-{code-smell,typescript}.yml` (sonnet), `reusable-quality-async.yml` (opus)
- **Accessibility**: `reusable-a11y-aria.yml` (sonnet), `reusable-a11y-wcag.yml` (opus)

All require `CLAUDE_CODE_OAUTH_TOKEN` secret. They analyze changed files in PRs and post findings as PR comments.

### Other

- **`reusable-sync-ai-rules.yml`** — syncs AI coding rules from this `.github` repo into calling repos via rulesync, creating a PR with tool-specific configs for Claude Code, Copilot, Gemini, and Cursor
- **`reusable-renovate.yml`** — centralized Renovate runner. Auths via a GitHub App token when `app-id` is set (with `APP_PRIVATE_KEY` secret), falling back to `GITHUB_TOKEN` otherwise. Scopes targets via `repositories` or `autodiscover`/`autodiscover-filter` inputs (default: the calling repo only); includes a ghcr.io host rule for container digest lookups

## Conventions

- **Commit messages**: [Conventional Commits](https://www.conventionalcommits.org/) — `type(scope): description`
- **Action pinning**: actions are pinned to full SHA with version comment (e.g., `actions/checkout@<sha> # v6.0.2`)
- **Concurrency groups**: workflows use concurrency groups to prevent racing (e.g., `release-please-${{ github.repository }}`)
- **Secret fallbacks**: workflows use `${{ secrets.CUSTOM_PAT || secrets.GITHUB_TOKEN }}` pattern for optional PATs
- **Permissions**: each workflow declares minimal `permissions` at workflow level

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
- **`reusable-auto-merge-image-updater.yml`** — creates, approves, and auto-merges ArgoCD Image Updater PRs in a single job (workaround for GITHUB_TOKEN anti-recursion)

### Claude-Powered Analysis Workflows

Security, quality, and accessibility workflows use `anthropics/claude-code-action@v1` with `--model haiku`:
- **Security**: `reusable-security-{secrets,deps,owasp}.yml`
- **Quality**: `reusable-quality-{code-smell,async,typescript}.yml`
- **Accessibility**: `reusable-a11y-{aria,wcag}.yml`

All require `CLAUDE_CODE_OAUTH_TOKEN` secret. They analyze changed files in PRs and post findings as PR comments.

### Other

- **`reusable-claude.yml`** — enables `@claude` mentions in issues and PRs
- **`reusable-renovate.yml`** — runs Renovate for dependency updates

## Conventions

- **Commit messages**: [Conventional Commits](https://www.conventionalcommits.org/) — `type(scope): description`
- **Action pinning**: actions are pinned to full SHA with version comment (e.g., `actions/checkout@<sha> # v6.0.2`)
- **Concurrency groups**: workflows use concurrency groups to prevent racing (e.g., `release-please-${{ github.repository }}`)
- **Secret fallbacks**: workflows use `${{ secrets.CUSTOM_PAT || secrets.GITHUB_TOKEN }}` pattern for optional PATs
- **Permissions**: each workflow declares minimal `permissions` at workflow level

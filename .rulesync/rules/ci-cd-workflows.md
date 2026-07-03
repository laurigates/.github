---
root: false
targets: ["claudecode", "copilot", "antigravity-cli", "cursor"]
description: "CI/CD workflow conventions — call org reusable workflows, pin actions to SHA, minimal permissions"
globs: ["**/.github/workflows/**"]
---
# CI/CD Workflow Conventions

## Rule: Call org reusable workflows — do not duplicate CI logic inline

CI/CD logic is centralized in [`laurigates/.github`](https://github.com/laurigates/.github). Application repos call the reusable workflows instead of defining build/release/review logic inline:

```yaml
uses: laurigates/.github/.github/workflows/reusable-<name>.yml@main
```

Key reusable workflows: container build/release (build-once/promote via GHCR), release-please, Claude PR review, auto-fix, conventional commit enforcement, sync-ai-rules.

## Rule: Pin third-party actions to a full commit SHA

Every third-party action is pinned to its full 40-character commit SHA with a trailing version comment:

```yaml
uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
```

Never pin to a mutable tag (`@v4`) or branch (`@main`) for third-party actions. Reusable workflows from `laurigates/.github` are the one exception — they are called with `@main`.

## Rule: Declare minimal workflow-level permissions

Every workflow declares an explicit `permissions:` block at workflow level, granting only what the jobs need:

```yaml
permissions:
  contents: read
```

Elevate individual scopes (`contents: write`, `pull-requests: write`) only when a step requires it.

## Rule: Use concurrency groups

Workflows that can race against themselves (release, deploy, PR checks) declare a concurrency group so superseded runs are cancelled or queued:

```yaml
concurrency:
  group: <workflow-name>-${{ github.ref }}
  cancel-in-progress: true
```

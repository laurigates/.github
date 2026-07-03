---
root: false
targets: ["claudecode", "copilot", "antigravity-cli", "cursor"]
description: "GitHub issue and PR metadata standards — assignee, type label, linked issue"
globs: ["**/*"]
---
# GitHub Metadata Hygiene

## Rule: Every issue and PR gets complete metadata

Apply at creation time, and backfill gaps when commenting on or reviewing existing issues/PRs.

### Issues

| Field | Requirement |
|-------|-------------|
| Assignee | Always set one (default: the repo owner) |
| Type label | Always set at least one: `bug`, `enhancement`, `chore`, `docs`, `security`, `refactor` |

### Pull Requests

| Field | Requirement |
|-------|-------------|
| Assignee | Always set one |
| Type label | Match the linked issue's labels; add a type label if missing |
| Linked issue | Reference the issue being addressed with `Closes #N` (or `Fixes #N`) in the PR body |

### Label conventions

| Label | When |
|-------|------|
| `bug` | Defect or broken behavior |
| `enhancement` | New feature or improvement |
| `chore` | Maintenance, dependency updates |
| `docs` | Documentation changes |
| `security` | Security-related fixes |
| `refactor` | Code restructure with no behavior change |

Check available labels with `gh label list` before applying — do not invent labels that don't exist in the repo.

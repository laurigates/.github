# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This is the **laurigates/.github** repository — a special GitHub repo that provides default community health files and reusable GitHub Actions workflows for all [@laurigates](https://github.com/laurigates) repositories. It contains no application code or build system; its own workflow tests live under `.github/tests/` (see [Testing](#testing)).

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

### Runner selection: `ubuntu-slim` for API-only jobs

Jobs whose entire body is GitHub-API churn — `gh` calls, `actions/github-script`,
`create-github-app-token`, release-please, label/PR bookkeeping — run on
**`ubuntu-slim`** (1 CPU, $0.002/min vs $0.006/min). Everything else stays on
`ubuntu-latest`.

`ubuntu-slim` is an *unprivileged container*, not a VM, and carries no hosted
tool cache. It therefore **cannot** run:

- anything needing a Docker daemon — including actions that only *look* like
  plain composites: `renovatebot/github-action`, `trufflesecurity/trufflehog`,
  `pypa/gh-action-pypi-publish` (`gitleaks/gitleaks-action` is `node24`, so it
  is fine)
- `container:` / `services:` jobs, `sudo`/`apt-get`, mounts, kernel features
- Go, Rust, Java/Gradle/Maven, .NET, Ruby, PHP, Swift, Android, browsers,
  databases, kubectl/helm, CMake/Bazel, CodeQL — none are preinstalled

Preinstalled and safe to rely on: bash, Node 24, Python 3.12, gcc/g++, git+LFS,
`gh`, jq, yq, curl, zstd, AWS/Azure/gcloud CLI. `actions/setup-node` /
`setup-python` still work but must *download* the runtime (no tool cache), so
prefer slim for jobs that don't need one.

When a job in a reusable workflow is split (a cheap gate + an expensive Claude
step), put only the gate on slim — see `reusable-changelog-review.yml` and
`reusable-auto-resolve-conflicts.yml`.

### Per-workflow notes

The workflow catalog is [docs/workflows.md](docs/workflows.md). What each workflow does internally, and what not to re-derive when changing it, is in a path-scoped rule under `.claude/rules/`; each loads when Claude reads or edits a workflow, action, test or doc it names in `paths:`.

| Rule | Covers |
|---|---|
| `workflow-container.md` | `reusable-container-{build,release}.yml`, `.github/actions/scan-image` |
| `workflow-release.md` | `reusable-release-please.yml`, `reusable-fix-release-conflicts.yml`, `reusable-clear-autorelease-labels.yml`, `reusable-auto-merge-image-updater.yml` |
| `workflow-claude-mention-review.md` | `reusable-claude.yml`, `reusable-claude-review.yml` (cost guard, evidence rules, re-enabling a caller) |
| `workflow-claude-code-action.md` | every `anthropics/claude-code-action` step: the `additional_permissions` trap |
| `workflow-auto-fix.md` | `reusable-auto-fix.yml` |
| `workflow-auto-resolve-conflicts.md` | `reusable-auto-resolve-conflicts.yml` |
| `workflow-conventional-commits.md` | `reusable-enforce-conventional-commits.yml`, `.github/actions/squash-message-check` |
| `workflow-merge-method.md` | `reusable-merge-method.yml` |
| `workflow-issue-enrich.md` | `reusable-issue-enrich.yml` |
| `workflow-changelog-review.md` | `reusable-changelog-review.yml` |
| `workflow-analysis.md` | `reusable-security-{secrets,owasp}.yml`, `reusable-quality-{code-smell,typescript,async}.yml`, `reusable-a11y-{aria,wcag}.yml` |
| `workflow-analysis-ruff.md` | `reusable-quality-code-smell.yml`'s ruff step |
| `workflow-gitleaks.md` | `reusable-security-secrets.yml`'s gitleaks job |
| `workflow-opencode.md` | `reusable-opencode.yml`, `reusable-opencode-review.yml` |
| `workflow-issue-labels.md` | `reusable-issue-labels.yml`, `.github/issue-labels.json` |
| `workflow-security-deps.md` | `reusable-security-deps.yml` |
| `workflow-bun-ci.md` | `reusable-bun-ci.yml` |
| `workflow-sync-ai-rules.md` | `reusable-sync-ai-rules.yml` |
| `workflow-renovate.md` | `reusable-renovate.yml`, `renovate.json` |

rulesync facts (the fetch path, removed targets, the pinned version) are in `.claude/rules/rulesync.md`, scoped the same way.

## Testing

`.github/workflows/lint.yml` gates every PR into `main` and every push to it: YAML validity, actionlint, shellcheck over the tracked `*.sh`, the publish-block drift check, a scratch-dir `rulesync generate`, and `bash .github/tests/run.sh`, which discovers and runs every `.github/tests/<name>/run.sh`. Locally:

```bash
just lint                     # yq YAML check + actionlint + shellcheck (warning severity) on tracked *.sh, at the pinned versions
just rules-check              # lint.yml's rulesync step: generate in a scratch copy, never at the root
just test                     # every test, via .github/tests/run.sh
just test workflow-contract   # only the named test(s)
```

A test passes only if it exits 0 **and** its last output line starts with `PASS: ` (print `PASS: <name> (<n> assertion(s))`); an exit-0 test without that line is reported FAIL, because it may have stopped before asserting anything, and the runner fails when it discovers no tests. A new test therefore needs no lint.yml step, and must not get one: `workflow-contract` rejects a step that runs a single test. Conventions are in `.github/tests/README.md`. The per-test recipes (`just publish-fixtures`, `just autofix-fixtures`, …) stay for running one harness against a non-default workflow path. Tests that guard the repo as a whole rather than one workflow:

- **`runner`** — the runner itself, against fixture tests in scratch repos: a test that reads stdin (or fd 3, where the runner keeps the list) cannot swallow the tests after it, a failing test is still reported after one, and a run whose count differs from the discovered count fails. Each test gets stdin from `/dev/null`; before that, a stub `gh` doing `cat > file` would have consumed the rest of the list and the runner would have printed "All 1 test(s) passed." with exit 0
- **`workflow-contract`** — every `reusable-*.yml` declares `workflow_call` and a top-level `permissions:` map; lint.yml runs the runner unconditionally and sets `persist-credentials: false` and `timeout-minutes`; every `uses: laurigates/.github/.github/{workflows,actions}/…` in a tracked file names something that exists here; and every `uses:` in a tracked workflow or composite action is `owner/repo[/path]@<40-hex SHA>` followed by a `# vX.Y.Z` comment, except this repo's own workflows and actions at `@main` and local `./` actions, so a tag, branch or short-SHA ref fails (#154). It finds each value with yq and reads the comment from that raw line
- **`tool-pins`** — every rulesync run through npx carries one exact `@X.Y.Z` version (lint.yml and `reusable-sync-ai-rules.yml` both run it), and lint.yml's `ACTIONLINT_VERSION` / `SHELLCHECK_VERSION` equal the justfile's `actionlint_version` / `shellcheck_version`, each download checked against its `*_SHA256`. Nothing tracks these automatically (Renovate runs here, but none of its managers, nor `renovate.json`'s Claude model manager, reads them), so a bump edits every site. The release binaries the reusable workflows download (`GITLEAKS_VERSION` in `reusable-security-secrets.yml`, `OSV_SCANNER_VERSION` in `reusable-security-deps.yml`, `OPENCODE_VERSION` in `reusable-opencode-review.yml`, `RUFF_VERSION` in `reusable-quality-code-smell.yml`) are tracked: a `github-releases` regex manager per pin in `renovate.json` opens the bump PR (#166), and `renovate-binary-pins` checks every `*_VERSION` pin (workflow, job or step `env:`) in those four workflows has one, and that each manager's description says whether CI catches a stale hash. Renovate cannot write the matching `*_SHA256`, so before merging the bump PR, replace the hash on it with the new release asset's (the asset and checksum file each workflow names beside the pin). Only the gitleaks and osv-scanner PRs fail a checksum check until then, because `gitleaks-guard` and `osv-scanner-job` run the real install on Linux x86_64; the ruff PR is red because `ruff-advisory` requires the fixture's `ruff_version` to equal `RUFF_VERSION`; the opencode PR is green, because `opencode-review` installs a stub tarball with its own hash, so a stale `OPENCODE_SHA256` would merge and break the review in every caller. For ruff also run `bash .github/tests/ruff-advisory/gen.sh <new ruff-x86_64-unknown-linux-gnu.tar.gz>` and commit the regenerated `ruff-output.json`
- **`sync-ai-rules-targets`** — the shipped `rulesync generate` passes `--targets`/`--features` equal to `rulesync.jsonc` and `fetch` passes `--path .rulesync`, the two exit-0-with-zero-files traps; the fetch step also binds `GITHUB_TOKEN`, because an anonymous fetch shares the hosted runners' 60-requests-an-hour limit and fails intermittently
- **`rulesync-ignore`** — `.rulesync/.aiignore` covers no tracked file, in particular not `.rulesync/` or `rulesync.jsonc`. Every line there becomes a `Read(...)` deny in each consumer's generated `.claude/settings.json`, which also blocks Edit, Write and path-naming Bash, so listing the rule source made it uneditable wherever it was synced
- **`claude-action-permissions`** — `additional_permissions` is a permissions map (see `.claude/rules/workflow-claude-code-action.md`), and a claude-code-action step that can run in tag mode, or allows `mcp__github_ci__*`, has `actions: read` on the job token
- **`issue-labels-taxonomy`** — `.github/issue-labels.json` passes the script's `check_taxonomy` rules for provisioning, uses only glob forms that git's glob pathspec and the script's matcher read alike, has no glob that matches no tracked file and no scope shared by two labels, and routes every reusable workflow, action and test. The script reads a stale glob or scope as "no label" and says nothing, and a new workflow or test without routing fails here

## Conventions

- **Commit messages**: [Conventional Commits](https://www.conventionalcommits.org/) — `type(scope): description`
- **Action pinning**: actions are pinned to full SHA with version comment (e.g., `actions/checkout@<sha> # v6.0.2`); this repo's own workflows and actions stay at `@main`. `workflow-contract` enforces both. `renovate.json` extends `helpers:pinGitHubActionDigests`, so Renovate writes and bumps action pins as `@<sha> # vX.Y.Z` rather than the exact tags the global config writes (#154), and lists `laurigates/.github` in `ignoreDeps`, because that preset would otherwise pin this repo's own `@main` references to `main`'s head and re-pin them on every push
- **Concurrency groups**: workflows use concurrency groups to prevent racing (e.g., `release-please-${{ github.repository }}`)
- **Secret fallbacks**: workflows use `${{ secrets.CUSTOM_PAT || secrets.GITHUB_TOKEN }}` pattern for optional PATs
- **Permissions**: each workflow declares minimal `permissions` at workflow level
- **Merging**: `main` requires the `lint` check on a branch that is up to date with it, so pull requests merge one at a time. After each merge every other open PR is refused with `Required status check "lint" is expected` until its branch is updated from `main` and `lint` has run again on the new head. `lint.yml` runs for pull requests into `main` only, on opened, synchronize and reopened: a PR stacked on another branch gets no `lint` run, and retargeting it to `main` starts none until the next push. Head branches are deleted on merge, so retarget a stacked PR to `main` before its base merges
- **One entry, one line**: each entry in this file and in the `.claude/rules/workflow-*.md` files is a single line, so two branches that edit the same entry, or two neighbouring ones, conflict when the second merges. Branches worked in parallel put their notes in entries that are not adjacent (a trial merge of the branches in a scratch worktree shows it before the PRs do)

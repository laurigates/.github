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

### Container Build/Release (build-once/promote pattern)

The container workflows implement a two-phase pattern:

1. **`reusable-container-build.yml`** (PR phase) — builds and pushes a `:next-{version}` pre-release image to GHCR during the release-please PR
2. **`reusable-container-release.yml`** (tag phase) — promotes the pre-built image via manifest retag (fast path) or falls back to full rebuild. Includes Trivy scanning and optional cosign keyless signing via Sigstore

The version is extracted from the version file (default: `package.json`) during build, and from the git tag (stripping `tag-prefix`) during release.

### Release Automation

- **`reusable-release-please.yml`** — wraps `googleapis/release-please-action`, requires a PAT (`MY_RELEASE_PLEASE_TOKEN`) since GITHUB_TOKEN can't trigger downstream workflows. Carries a **missed-release guard**: when the action reports neither `prs_created` nor `releases_created`, a follow-up step compares `github.event.before...github.sha` via the GitHub compare API and annotates (or fails, per `missed-release-check`) if the range held commits matching `releasable-types`. This exists because release-please's conventional-commit parser can throw on a squash body — repos with `squash_merge_commit_message = PR_BODY` inherit the PR description as the commit body, and a fenced code block there discards *every* commit in the range while the run stays green (issue #40). The guard only catches the all-or-nothing case; the root-cause fix is per-repo `squash_merge_commit_message = COMMIT_MESSAGES` in gitops

  Also **assigns the release PR** (`pr-assignees`, defaulting to `github.repository_owner`). release-please has no native assignee config, and its PRs are bot-authored and mention no one, so they match none of GitHub's dashboard/mobile feeds — not `author:@me`, not `review-requested:@me`, not even `involves:@me`; an assignee is the only thing that files them under a human. Two things not to re-derive: **`@me` is unusable** — `gh` resolves it to the *token* owner, which is the App bot whenever `app-id` is set — and the step must run *before* the missed-release guard, since `missed-release-check: error` would otherwise skip it. It reads `steps.release.outputs.prs` (set on create *and* update, one entry per package in manifest mode) and falls back to listing open `release-please--branches--*` PRs when that output is empty, so an already-open PR still gets assigned. Assign failures warn rather than fail the release. Set `pr-assignees: none` to opt out — `''` cannot be the opt-out because it means "fall back to the owner"
- **`reusable-fix-release-conflicts.yml`** — detects conflicted release-please PRs, closes them, deletes the branch, and retriggers release-please to recreate cleanly
- **`reusable-clear-autorelease-labels.yml`** — manual escape hatch (`workflow_dispatch` caller) that strips a stale `autorelease: pending` label from closed PRs. When the release/tag step fails, the merged release PR keeps the `pending` label and every subsequent run re-attempts the same failed release; clearing it lets release-please move on. Supports a `dry_run` input
- **`reusable-auto-merge-image-updater.yml`** — creates, approves, and auto-merges ArgoCD Image Updater PRs in a single job (workaround for GITHUB_TOKEN anti-recursion)

### Claude-Powered Workflows

- **`reusable-claude.yml`** — enables `@claude` mentions in issues and PRs. Supports configurable runner, max turns, and system prompt for CI turn budget awareness. Posts continuation comments on max-turns exhaustion
- **`reusable-claude-review.yml`** — automated PR review using Claude Code. Skips release-please PRs and bot actors by default
- **`reusable-auto-fix.yml`** — analyzes failed CI workflows and either auto-fixes (commit + push) or opens a GitHub issue. Includes flood guards and recent-fix detection to prevent loops. Its tool list was inert (see the trap below), which silently disabled the commit/push and issue-creation the workflow exists for; it also never forwarded `actions: read`, so Claude could not read CI results either
- **`reusable-enforce-conventional-commits.yml`** — auto-fixes PR titles to conventional commits format with 80+ verb-to-type mappings
- **`reusable-changelog-review.yml`** — scheduled upstream-changelog triage (Claude Code's changelog by default). Two-job shape: a pure-bash pre-check gate (version compare against a tracking JSON, skip-if-existing-open-issue idempotency, excerpt slicing, caller-supplied analyzer script) followed by one opus triage run that opens a single tracking issue and a single JSON-ratchet PR. The schedule lives in the caller (`workflow_call` cannot carry one); the repo-specific keyword→file mapping stays in the calling repo via the required `analyzer-script` input. Model/effort default to opus/medium via inputs

  Three things not to re-derive:
  - **The tool list belongs in `claude_args: --allowedTools`, never in `additional_permissions:`.** That input takes a GitHub *permissions map* (`actions: read`); a Claude tool list there is silently inert, the action's default policy then denies `gh issue create` / `git push`, and **the SDK exits 0 on a permission denial** — so the workflow runs green and files nothing. It did exactly that for 13 consecutive weeks in claude-plugins. Diagnose from the job log's `SDK options:` block: `allowedTools` absent = broken. **Do not gate on `permission_denials_count > 0`** — a healthy run has one, from the deliberately un-granted `WebFetch`. The same inert list was also converted in `reusable-auto-fix.yml` and `reusable-claude-review.yml`; see **The `additional_permissions` trap** below
  - **Labels are provisioned by the gate job, before the triage run.** `gh issue create --label <unknown>` hard-fails on the prompt's last step, after the whole analysis is paid for. The colour is a *quoted* string: bare `5319e7` is a YAML 1.2 float (`53190000000`) and `gh label create` answers HTTP 422. Create-if-missing rather than `--force`, so a shared label like `maintenance` is not recoloured weekly
  - **A backlog is windowed, not truncated** (`max-versions-per-run`, default 25 — the review-stall threshold the consumer's own analyzer enforces). The excerpt is newest-first, so the old byte cap kept the newest bytes and dropped the oldest versions *while still ratcheting to the top of the range*, skipping them for good. Windowing instead keeps the **oldest** N versions after `lastCheckedVersion` and ratchets only to the top of that window; the next run continues from there because upstream's latest still exceeds the new tracked version. Downstream consumers must use the `effective_latest` output, never `latest_version`

#### The `additional_permissions` trap

`anthropics/claude-code-action`'s `additional_permissions:` input takes a **GitHub permissions map** — `actions: read` and nothing else. A Claude **tool list** written there is silently inert: no `allowedTools` reaches the SDK, the action's default policy denies the writes, and **the SDK exits 0 on a permission denial**, so the run goes green having done nothing. Three workflows here had it; `reusable-claude.yml` always had it right and is the canonical shape:

- tools go in an `allowed_tools` input (comma-separated), composed into `claude_args` as `--allowedTools "..."` — a **separate input from `claude_args`** on purpose, so a caller overriding `--model`/`--max-turns` cannot silently drop the tool grant. `reusable-changelog-review.yml` is the deliberate exception: its list is pinned inline and not caller-tunable, because the *exclusions* (`WebFetch`/`WebSearch`) are part of its prompt's contract that the pre-sliced excerpt is the only input
- `additional_allowed_tools` appends caller extras; `additional_permissions` is the permissions map only
- `--allowedTools` is **additive** over the action's defaults, so listing tools widens rather than restricts
- naming `TodoWrite` is a real grant, not decoration — since 2.1.233 the todo/task tools are off by default on current models and listing one is the session-wide opt-in
- diagnose from the job log's `SDK options:` block: `allowedTools` absent = broken

#### Claude-Powered Analysis Workflows

Security, quality, and accessibility workflows use `anthropics/claude-code-action@v1`. Each exposes `max-turns` (default 50) and `model` inputs — opus for deep-reasoning jobs, sonnet for the more mechanical ones:
- **Security**: `reusable-security-{secrets,deps}.yml` (sonnet), `reusable-security-owasp.yml` (opus)
- **Quality**: `reusable-quality-{code-smell,typescript}.yml` (sonnet), `reusable-quality-async.yml` (opus)
- **Accessibility**: `reusable-a11y-aria.yml` (sonnet), `reusable-a11y-wcag.yml` (opus)

All require `CLAUDE_CODE_OAUTH_TOKEN` secret. They analyze changed files in PRs and publish findings to the **job summary and PR file annotations** — never a PR comment. The action grants no comment tool, so a prompt asking Claude to comment only produced denials and discarded the findings (issue #47); `$GITHUB_STEP_SUMMARY` and `::warning`/`::error` both work under the `contents: read` these jobs already hold, and need nothing in `additional_permissions:`.

Three things not to re-derive:
- **The publish block is byte-identical across all eight**, bar four env values (`TITLE`, `BLOCKING_SEVERITIES`, `COUNT_KEYS`, `NOTHING_SCANNED_REASON` — masked in the drift check, so a per-workflow message stays possible without forking the block). It is duplicated on purpose: `uses:` takes no expressions, so a shared composite action would execute at floating `@main` even for a consumer who pinned this repo by SHA, and a script under `.github/` is not checked out either (these jobs run `actions/checkout` with no `repository:`, so the workspace is the *caller's*). `scripts/check-publish-drift.sh` (`just publish-drift`) enforces the identity and fails on absence as well as drift.
- **Every gate predicate compares numerically** (`steps.publish.outputs.blocking > 0`), never as a string (`!= '0'`), and none carries `always()`. GitHub coerces the empty string a skipped publish step leaves behind to 0 for `>`, so a numeric gate cannot fire on a PR that scanned nothing; string comparison does the opposite and would take every consumer red on a README-only PR.
- **The fixture harness EXTRACTS the shipped block** out of a workflow with `awk`/`sed` rather than holding a retyped copy (`just publish-fixtures`). That is what caught the annotation-escaping, non-object-element and `index()`-scope defects; a retyped copy is not the code under test.
- **Everything the model emits is untrusted at the shell boundary**, `--json-schema` notwithstanding: the `enum` on `severity` and the `integer` on the counts are requests to the model, not constraints the runner applies. So annotation payloads (`severity` included) are `%`/CR/LF-escaped; `line` and the counts are type-checked, since a count carrying a newline writes a second `key=value` line into `$GITHUB_OUTPUT` and can overwrite `blocking`; and `findings` is shape-checked in the guard, because a non-array aborts jq under `set -e` and discards summary, annotations and outputs together.

### OpenCode-Powered Workflows

- **`reusable-opencode.yml`** — enables `/opencode` (or `/oc`) mentions in issue comments and PR review comments, via `anomalyco/opencode/github`. Requires the `OPENCODE_API_KEY` secret (pushed by gitops to repos flagged `opencode = true`).

  **There is no automatic-review mode, by construction.** The action's `github/index.ts` opens with `assertContextEvent("issue_comment", "pull_request_review_comment")` and throws `Unsupported event type` on anything else, then throws again unless the body matches `/(?:^|\s)(?:\/opencode|\/oc)(?=$|\s)/`. A `pull_request`-triggered caller therefore cannot work — the only route to automatic review is a shim that posts a `/oc` comment on PR open, which needs a PAT or App token (comments made with `GITHUB_TOKEN` do not trigger workflows).

  Two details worth not re-deriving:
  - The job's `if:` is a deliberately loose `contains()` pre-filter; a **guard step** then applies the action's exact regex and skips the action when the mention is only a substring (`/october`). Without it, such a comment spins a runner and fails red on the action's own throw. The comment body reaches the guard via `env:`, never interpolated into the script — it is attacker-controlled.
  - The action is pinned to a release SHA, but **pinning does not fully close the floating-version exposure**: `action.yml`'s first step `curl`s the *latest* opencode CLI release at runtime regardless of the pin. The pin covers the wrapper, not the binary it installs. Fix proposed upstream in [anomalyco/opencode#39147](https://github.com/anomalyco/opencode/pull/39147) — runs the installer bundled at the pinned ref and adds a `version` input passed to the installer. If it lands, bump the pinned SHA and set `version` in the reusable workflow to close the gap; until then the caveat stands.

  Auth defaults to the OpenCode App OIDC exchange (`id-token: write`), which needs the [opencode-agent App](https://github.com/apps/opencode-agent) installed on the calling repo; set `use_github_token: true` to use `GITHUB_TOKEN` instead. Note the action requires the commenting actor to hold **write or admin** permission, so outside contributors cannot drive it.

### Other

- **`reusable-sync-ai-rules.yml`** — syncs AI coding rules from this `.github` repo into calling repos via rulesync, creating a PR with tool-specific configs for Claude Code, Copilot, Gemini, and Cursor
- **`reusable-renovate.yml`** — centralized Renovate runner. Auths via a GitHub App token when `app-id` is set (with `APP_PRIVATE_KEY` secret), falling back to `GITHUB_TOKEN` otherwise. Scopes targets via `repositories` or `autodiscover`/`autodiscover-filter` inputs (default: the calling repo only); includes a ghcr.io host rule for container digest lookups

## Conventions

- **Commit messages**: [Conventional Commits](https://www.conventionalcommits.org/) — `type(scope): description`
- **Action pinning**: actions are pinned to full SHA with version comment (e.g., `actions/checkout@<sha> # v6.0.2`)
- **Concurrency groups**: workflows use concurrency groups to prevent racing (e.g., `release-please-${{ github.repository }}`)
- **Secret fallbacks**: workflows use `${{ secrets.CUSTOM_PAT || secrets.GITHUB_TOKEN }}` pattern for optional PATs
- **Permissions**: each workflow declares minimal `permissions` at workflow level

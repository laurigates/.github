---
paths:
  - ".github/workflows/reusable-release-please.yml"
  - ".github/workflows/reusable-fix-release-conflicts.yml"
  - ".github/workflows/reusable-clear-autorelease-labels.yml"
  - ".github/workflows/reusable-auto-merge-image-updater.yml"
  - ".github/tests/fix-release-conflicts-token-scopes/**"
  - ".github/tests/auto-merge-retry/**"
  - ".github/tests/conflict-mergeable-wait/**"
  - "docs/releases.md"
---

# Release Automation

- **`reusable-release-please.yml`** — wraps `googleapis/release-please-action`, requires a PAT (`MY_RELEASE_PLEASE_TOKEN`) since GITHUB_TOKEN can't trigger downstream workflows. Carries a **missed-release guard**: when the action reports neither `prs_created` nor `releases_created`, a follow-up step compares `github.event.before...github.sha` via the GitHub compare API and annotates (or fails, per `missed-release-check`) if the range held commits matching `releasable-types`. This exists because release-please's conventional-commit parser can throw on a squash body — repos with `squash_merge_commit_message = PR_BODY` inherit the PR description as the commit body, and a fenced code block there discards *every* commit in the range while the run stays green (issue #40). The guard only catches the all-or-nothing case; the root-cause fix is per-repo `squash_merge_commit_message = COMMIT_MESSAGES` in gitops

  Also **assigns the release PR** (`pr-assignees`, defaulting to `github.repository_owner`). release-please has no native assignee config, and its PRs are bot-authored and mention no one, so they match none of GitHub's dashboard/mobile feeds — not `author:@me`, not `review-requested:@me`, not even `involves:@me`; an assignee is the only thing that files them under a human. Two things not to re-derive: **`@me` is unusable** — `gh` resolves it to the *token* owner, which is the App bot whenever `app-id` is set — and the step must run *before* the missed-release guard, since `missed-release-check: error` would otherwise skip it. It reads `steps.release.outputs.prs` (set on create *and* update, one entry per package in manifest mode) and falls back to listing open `release-please--branches--*` PRs when that output is empty, so an already-open PR still gets assigned. Assign failures warn rather than fail the release. Set `pr-assignees: none` to opt out — `''` cannot be the opt-out because it means "fall back to the owner"
- **`reusable-fix-release-conflicts.yml`** — detects conflicted release-please PRs, closes them, deletes the branch, and retriggers release-please to recreate cleanly. Pass `app-id` + `APP_PRIVATE_KEY` to use an App token instead of `RELEASE_PLEASE_TOKEN || GITHUB_TOKEN`. The token used (App or PAT) needs `actions: write` as well as contents and pull-requests write, because the workflow's `permissions:` block covers only `GITHUB_TOKEN`; without it the job closes the PR and deletes the branch, then fails on the `gh workflow run` dispatch, and nothing recreates the release PR until the next push to main (issue #114)
- **`reusable-clear-autorelease-labels.yml`** — manual escape hatch (`workflow_dispatch` caller) that strips a stale `autorelease: pending` label from closed PRs. When the release/tag step fails, the merged release PR keeps the `pending` label and every subsequent run re-attempts the same failed release; clearing it lets release-please move on. Supports a `dry_run` input
- **`reusable-auto-merge-image-updater.yml`** — creates, approves, and auto-merges ArgoCD Image Updater PRs in a single job (workaround for GITHUB_TOKEN anti-recursion)

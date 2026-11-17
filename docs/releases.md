# Releases

How a PR reaches `main` and becomes a release: the merge method, the
release-please safeguards, and finding the release PR.

## Merge Method

A PR is merged with **Rebase and merge** or **Squash and merge**, never a merge
commit. Rebase keeps each conventional commit on `main`, so a multi-concern PR
stays revertable per commit; squash fits everything else. release-please reads
the commits that land, so the choice decides what appears in the changelog.

In a repo that calls `reusable-merge-method.yml`:

- A `merge-method` check on the PR names the button to press in its title, for
  example "→ Squash and merge (…)", with the reason in the parentheses. It is
  informational, never required.
- The workflow keeps one `merge:rebase` or `merge:squash` label on the PR to
  match.
- **To override**, apply the other `merge:*` label yourself. A label a human
  applies wins over the rule table.

Roughly: two or more clean, independent conventional commits rebase; a single
commit, bot and release PRs, merge commits from syncing `main`, fixups and
review churn, non-conventional subjects, and in-PR corrections squash. The
ordered rule table is
[`merge-strategies.md`](https://github.com/laurigates/claude-plugins/blob/main/git-plugin/skills/github-pr-title/merge-strategies.md)
in `laurigates/claude-plugins`.

GitHub's merge button defaults to the method you last used in that repo, so
read the check title before clicking.

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

## Squash Commit Parse Check

In a repo with `squash_merge_commit_message = PR_BODY`, GitHub builds the squash
commit from the PR title, ` (#N)` and the description hard-wrapped at 72
columns (lines under a column-0 fenced block are left alone). A wrap that puts
a mid-sentence call such as `name(` at the start of a line makes
release-please's conventional-commit parser throw, and release-please drops the
commit: a feat/fix PR merges green and cuts no release. The description as
written may parse.

`reusable-enforce-conventional-commits.yml` can check this before merge. With
`squash-message-check: warn` (annotate) or `error` (fail the job), a second job
runs after the title fixer, reads the current title and description from the
API, rebuilds the squash message and parses it with `@conventional-commits/parser`
at the version `reusable-release-please.yml`'s release-please-action pin
bundles. It reports the parser error, the line number and the line. It also
runs when the title check fails. The parser stops at its first error, so it then
parses the description under a placeholder title, and reports the title only as
a notice, since the title check already fails on it.

```yaml
on:
  pull_request:
    types: [opened, edited, synchronize]

jobs:
  conventional-commits:
    uses: laurigates/.github/.github/workflows/reusable-enforce-conventional-commits.yml@main
    with:
      squash-message-check: warn   # off (default) | warn | error
```

Leave it `off` in repos that squash with `COMMIT_MESSAGES`. To fix a reported
line, reword the sentence, or add a `BEGIN_COMMIT_OVERRIDE` /
`END_COMMIT_OVERRIDE` section with the intended commit message to the
description.

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

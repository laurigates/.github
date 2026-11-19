# Issue Labels

What the labels on issues and pull requests in the laurigates repositories mean,
who applies them, and how to add one. This page is the human-facing summary;
the agent-facing reference with the full rules is the
[`github-labels` skill](https://github.com/laurigates/claude-plugins/blob/main/git-plugin/skills/github-labels/SKILL.md)
in `laurigates/claude-plugins`.

## The label families

An open issue carries one **type** label and at least one **routing** label
(`build:`, `area:` or `core:`). The **waiting** labels are added only while
something stops the issue being picked up.

| Family | Labels | Says |
|--------|--------|------|
| Type | `bug`, `enhancement`, `chore`, `docs`, `security`, `refactor` | The kind of change. One per issue or PR |
| Routing: build | `build:<name>` | The build in a monorepo the issue belongs to: one firmware, app or package among several |
| Routing: area | `area:<name>` | A toolchain or subsystem that cuts across builds |
| Routing: core | `core:ci`, `core:quality`, `core:agent`, `core:build`, `core:components`, `core:docs` | Repo-wide machinery that belongs to no single build or area |
| Waiting | `needs:hardware`, `needs:decision`, `needs:human` | The issue waits on the maintainer |
| Waiting | `blocked` | The issue waits on another issue, PR or upstream change |
| Dependencies | `dependencies`, `github-actions`, `opentofu` | Dependency-update PRs from Renovate or Dependabot |
| Merge method | `merge:rebase`, `merge:squash` | How the PR is merged. The merge-method workflow applies one; a label a human applies overrides it |

`build:` and `area:` names differ per repository. A repository without a
taxonomy file uses only the type, `core:` and waiting labels.

## Where each label is defined

| Labels | Defined in | Applied to |
|--------|-----------|------------|
| Type, dependency, merge-method | [`gitops/labels.tf`](https://github.com/laurigates/gitops/blob/main/labels.tf) (`standard_labels`) | Every non-archived managed repo |
| `core:*`, `needs:*`, `blocked` | [`gitops/labels.tf`](https://github.com/laurigates/gitops/blob/main/labels.tf) (`triage_labels`) | Non-archived managed repos that are not forks |
| `build:*`, `area:*` | The repository's own `.github/issue-labels.json` | That repository only |

Labels from `gitops/labels.tf` reach a repository at the next gitops release.
Do not create them with `gh label create`; the next apply rewrites them.

## The waiting labels

Scheduled routines and CI agents skip an issue that carries any of these.

| Label | Added when | Removed when |
|-------|-----------|--------------|
| `needs:hardware` | The next step needs a physical action at the bench: a verification, test print or measurement. The issue says what to do and what to report | The maintainer posts the result |
| `needs:decision` | An agent stopped on a choice that is the maintainer's. A comment gives the options and a recommendation | The decision is recorded in a comment |
| `needs:human` | The work can land only with the maintainer's live session, credentials or local data, or from a scheduled run the maintainer sets up | The work lands |
| `blocked` (blocker is an issue) | A `blocked_by` dependency link is added to the issue | The issue-labels workflow removes it when the last linked blocker in the same repository closes |
| `blocked` (blocker is a PR or upstream change) | A comment names the PR or upstream change | By hand, when that blocker lands |

No automation removes a `needs:` label.

## Automatic labelling

Repositories that call the
[`reusable-issue-labels.yml`](../.github/workflows/reusable-issue-labels.yml)
workflow get labels applied and checked from their taxonomy file:

- **New, reopened or edited issue**: type and routing labels are derived from
  the title (`fix(parser): …` or `[Bug] parser: …`). With no routing label from
  the title, paths quoted in the body are used.
- **New, updated or edited PR**: the type label comes from the title and a
  routing label from each changed file. Fork PRs and Dependabot PRs are
  skipped, and a caller can switch PR labelling off.
- In both cases labels are only added: a group (type, or one routing prefix)
  that already has a label is left alone.
- **Push to the default branch**: the `build:` and `area:` labels in
  `.github/issue-labels.json` are created, updated or renamed. Nothing is
  deleted.
- **Issue closed**: `blocked` is removed from issues whose linked blockers are
  all closed.
- **Scheduled audit**: lists open issues with no type label, no routing label,
  `blocked` with no link, an open blocker link without `blocked`, or a `needs:`
  label older than 30 days, in the job summary and one rolling issue. A manual
  `backfill` run labels open issues that lack a type or routing label.

The workflow's file header lists which event runs which job.

## Enriching a terse issue

Repositories that also call
[`reusable-issue-enrich.yml`](../.github/workflows/reusable-issue-enrich.yml)
let the owner file an issue with a short title and a line or two of text.
Claude then rewrites it into What, Why, Context, Acceptance and Open questions
sections, using the repository's code, docs and open issues as context, and
labels it. The original title and body are kept in a collapsed block at the
end of the new body.

- It runs only on issues the repository owner opens. Other people's issues
  are left alone.
- If the owner edits the issue while Claude is drafting, the rewrite is
  dropped and the owner's version stays.
- Labels: the classifier runs again on the rewritten text, then Claude's
  proposals fill type and routing groups that are still empty. Claude never
  sets `needs:` labels or `blocked`.

## Adding a `build:` or `area:` label

Add an entry to `.github/issue-labels.json` in the repository: the label name,
colour, description, and the paths and title scopes that select it. The next
push to the default branch creates the label. To rename one, give the new entry
a `renamed_from` field so existing issues keep it. The file format is in the
[`github-labels` skill](https://github.com/laurigates/claude-plugins/blob/main/git-plugin/skills/github-labels/SKILL.md).

A label that only one repository needs and that is not `build:` or `area:` can
be created with `gh label create` in that repository.

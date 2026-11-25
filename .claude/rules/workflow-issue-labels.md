---
paths:
  - ".github/workflows/reusable-issue-labels.yml"
  - ".github/workflows/issue-labels.yml"
  - ".github/issue-labels.json"
  - ".github/tests/issue-labels/**"
  - ".github/tests/issue-labels-taxonomy/**"
  - "docs/issue-labels.md"
---

# `reusable-issue-labels.yml`

- **`reusable-issue-labels.yml`** — keeps issue and PR labels in step with a repository's label taxonomy, with no model. Every decision is `git-plugin/scripts/issue-labels.py` from laurigates/claude-plugins at the commit pinned in the `plugins-ref` input, which `renovate.json` bumps (see `.claude/rules/workflow-renovate.md`); the vocabulary and who sets and clears each label are in `git-plugin/skills/github-labels/SKILL.md` there and, in short form, in `.rulesync/rules/github-metadata-hygiene.md` here. The caller's event picks the job:

  | Caller event | Job | Does |
  |---|---|---|
  | `push` to the default branch | `provision` | Creates, updates or renames the `build:` and `area:` labels that `.github/issue-labels.json` defines. Deletes nothing. No taxonomy file: a notice, exit 0. `provision: false` skips the job, for a caller whose labels are managed as IaC (#178) |
  | `issues` opened, reopened, edited | `classify-issue` | Adds the type and routing labels the title points at, or with no routing label the paths the body quotes. `edited` is skipped when a bot made the edit (the event's `sender`) |
  | `issues` closed | `unblock` | Removes `blocked` from each open issue this one was blocking whose `blocked_by` issues are all closed |
  | `pull_request` opened, synchronize, reopened, edited | `classify-pr` | Adds the type label from the title and a routing label per changed file; `edited` re-classifies after a title change. Skipped for fork PRs, Dependabot, heads matching `skip-heads` (default `release-please--*`) and `pr-labels: false` |
  | `schedule`, `workflow_dispatch` | `sweep` | `mode: audit` writes the findings to the job summary and to one rolling `Issue label audit` issue; `mode: backfill` classifies open issues that lack a type or routing label, oldest first, at most `max-issues` (25) per run. With no taxonomy file the audit report leaves out `missing_routing` findings, since that repository has no `build:` or `area:` label an issue could take (#152); backfill still takes them as candidates. "No file" is a 404 from the contents API at the default branch, read only when there is such a finding; any other failed read fails the step before anything is reported |

  The model stage for issues the classifier leaves unlabelled is not built (#147). Six things not to re-derive:
  - **Every write uses `github.token`, and that is what prevents a loop.** A label written with it starts no workflow, so neither this workflow nor a caller that listens for label events (merge-method) runs again. A PAT or App token here would make each label write an event
  - **The calling repository is never checked out.** The only checkout is the script, from laurigates/claude-plugins. The taxonomy is read through the contents API at the default branch and titles and bodies through the API by number, so a pull request cannot change the taxonomy that labels it, and no `run:` body holds an expression. The head branch name reaches the `skip-heads` gate through `env:`
  - **Additive, and only labels that exist.** The steps send `add` from the script's `classify` output and nothing else: a label whose group (type, or one routing prefix) is still empty on the item and which the repository has. Adding a missing label to an issue through REST would create it. The standard labels (`core:*`, `needs:*`, `blocked`, the type labels) come from laurigates/gitops `labels.tf`; `provision` writes `build:` and `area:` only. No step edits a title or body
  - **A step writes only when `dry-run` is exactly `false`.** Any other value, an unset one included, prints what would change. For `provision` and `unblock` that is the script's `--dry-run`
  - **One caller grant, narrower per job.** The caller grants `contents: read`, `issues: write`, `pull-requests: write`. A job that asks for more than the caller grants fails the run at startup on every event, including events that job does not run on, so a new scope here (`id-token: write` for a model stage) breaks every caller until each one grants it
  - **The audit issue is filed once and commented on only when the findings change.** It is found by exact title among open issues opened by `github-actions[bot]` (`app/github-actions` in `gh issue list --json author`), so an issue anyone else opens with that title is not adopted. A hidden marker holds a hash of the (finding type, issue number) pairs it reports, and a run whose hash equals the latest marker posts nothing. Issue numbers are in a code block, because a linked number would add a cross-reference to every listed issue on each report; the job summary has the links. It is closed by hand, and the next audit with findings files a new one. A new audit issue is assigned to `audit-assignee`, or with that empty to the repository owner only when `users/<owner>` reports a user account: an organization login cannot be assigned (#177). `none` assigns nobody

  Caller (`.github/workflows/issue-labels.yml`). List the `types:` explicitly: a bare `issues:` also starts a run for every label event.

  ```yaml
  name: Issue labels
  on:
    issues:
      types: [opened, reopened, edited, closed]
    pull_request:
      types: [opened, synchronize, reopened, edited]
    push:
      branches: [main]
      paths: [.github/issue-labels.json]
    schedule:
      - cron: '17 5 * * 1'
    workflow_dispatch:
      inputs:
        mode:
          description: 'audit reports label gaps; backfill labels open issues that lack a type or routing label'
          type: choice
          options: [audit, backfill]
          default: audit
        dry-run:
          description: 'Print what would change and write nothing'
          type: boolean
          default: true
  permissions:
    contents: read
    issues: write
    pull-requests: write
  jobs:
    issue-labels:
      uses: laurigates/.github/.github/workflows/reusable-issue-labels.yml@main
      with:
        mode: ${{ inputs.mode || 'audit' }}
        dry-run: ${{ inputs.dry-run || false }}
  ```

  `.github/tests/issue-labels/run.sh` (`just test issue-labels`) checks the parsed workflow for the token, expression, checkout, permission and write-call rules above, evaluates each job and step `if:` and concurrency group over a matrix of event contexts, then runs the extracted step bodies against a stub `gh` and a stand-in for the script. What only a caller's run can show is listed in #148

  This repository calls it from `.github/workflows/issue-labels.yml` with `pr-labels: false` and no `pull_request` trigger, and its taxonomy is `.github/issue-labels.json` (one `area:` label per workflow family; `core:ci` covers only this repository's own CI). That caller's runs exercise the `issues`, `push` and `schedule` events here; `classify-pr` and the pull-request items in #148 still need a consumer that labels pull requests

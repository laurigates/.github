---
paths:
  - ".github/workflows/reusable-merge-method.yml"
  - ".github/workflows/merge-method.yml"
  - ".github/tests/merge-method/**"
---

# `reusable-merge-method.yml`

- **`reusable-merge-method.yml`** — posts a `merge-method` check run whose title names the merge button to press ("→ Rebase and merge (…)" / "→ Squash and merge (…)"), and keeps one bot-applied `merge:rebase` / `merge:squash` label on the PR. The decision is `git-plugin/scripts/pr-merge-method.py` from laurigates/claude-plugins at the commit pinned in the `plugins-ref` input, which `renovate.json` bumps (see `.claude/rules/workflow-renovate.md`). The same script backs the git-plugin `gh pr merge` hook, and its rule table is `git-plugin/skills/github-pr-title/merge-strategies.md`. Four things not to re-derive:
  - **Never required.** GitHub gives a check no way to know which method the merge will use, and the merge-button default (`viewerDefaultMergeMethod`) is per user and read-only, so the check can only advise. A required check would also break the gitops rule against requiring reusable-workflow callers
  - **A human label is an override, the bot label is not.** The script reads the latest `labeled` event's actor for each `merge:*` label; under an override the workflow keeps the human label and removes the opposite one, so the PR never shows both. Writes made with `GITHUB_TOKEN` start no workflow, so the caller's `labeled`/`unlabeled` triggers fire only on human changes and the workflow cannot loop on its own label
  - **The labels come from laurigates/gitops `labels.tf`.** The workflow never creates them; a repo without them still gets the check run, plus a `::warning::`
  - **Body lint appears only where the body lands.** The script lints the PR body only for a squash, of a human PR, on a repo whose `squash_merge_commit_message` is `PR_BODY`. gitops sets `COMMIT_MESSAGES` on release-please repos until laurigates/gitops#318

  `.github/tests/merge-method/run.sh` runs the extracted publish step against a stub `gh` (`just test merge-method`)

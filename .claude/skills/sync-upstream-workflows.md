# Sync Upstream Workflows

Sync reusable workflow improvements from the ForumViriumHelsinki/.github organization repo into this personal laurigates/.github repo.

## Context

Both repos share the same set of reusable GitHub Actions workflows. The FVH org repo is the upstream source where improvements are typically developed first, then ported here. Some workflows in this repo have personal enhancements (e.g., plugin inputs in reusable-claude.yml, expanded verb aliases in reusable-enforce-conventional-commits.yml) that must be preserved during sync.

## Repos

- **Upstream (FVH org)**: `/Users/lgates/repos/ForumViriumHelsinki/.github/.github/workflows/`
- **Personal**: `/Users/lgates/repos/laurigates/.github/.github/workflows/`

## Steps

1. **Identify changed workflows upstream**
   - `just upstream-changes [days]` — recent FVH commits touching `reusable-*.yml`
   - `just diff-upstream` — per-workflow DIFFERS / identical / personal-only / upstream-only table
   - `just diff-upstream-detail <name>` — full diff for one workflow
   - Classify differences as: upstream improvement, personal enhancement, or cosmetic (org name)

2. **Review each difference**
   - For each upstream improvement, verify it's applicable to personal repos
   - For each personal enhancement, confirm it should be preserved
   - Flag any conflicts where both repos diverged on the same section
   - **The personal repo may be intentionally AHEAD of upstream** on a workflow
     (e.g. model/turns inputs, sticky comments, structured_output schemas landed
     here first). Reconcile: graft the upstream feature into the local shape —
     never blind-copy the whole upstream file. Worked example: PR #30 ported
     only bun-audit + allowed-bots from an upstream file that was otherwise
     behind the local one.

3. **Apply upstream improvements**
   - Port functional changes (bug fixes, new features, permission changes)
   - Preserve personal enhancements (plugin inputs, expanded aliases, org-specific refs)
   - Update org-specific references (e.g., `ForumViriumHelsinki` -> `laurigates` in examples/comments)

4. **Verify**
   - `just leak-check` — fails if upstream-org identifiers leaked into this repo's sources
   - `just lint` — YAML validity + actionlint

For `reusable-sync-ai-rules.yml` and the `.rulesync/` source content, see
`.claude/rules/rulesync.md` (rulesync v9 CLI gotchas — fetch path, removed
targets, generate defaults).

## Expected Cosmetic Differences (ignore these)

These differences are intentional and should NOT be synced:
- Organization name in example `uses:` lines (`laurigates/.github/...` vs `ForumViriumHelsinki/.github/...`)
- `certificate-identity-regexp` URLs in cosign verification
- Repository references in `reusable-sync-ai-rules.yml`

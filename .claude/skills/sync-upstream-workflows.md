# Sync Upstream Workflows

Sync reusable workflow improvements from the ForumViriumHelsinki/.github organization repo into this personal laurigates/.github repo.

## Context

Both repos share the same set of reusable GitHub Actions workflows. The FVH org repo is the upstream source where improvements are typically developed first, then ported here. Some workflows in this repo have personal enhancements (e.g., plugin inputs in reusable-claude.yml, expanded verb aliases in reusable-enforce-conventional-commits.yml) that must be preserved during sync.

## Repos

- **Upstream (FVH org)**: `/Users/lgates/repos/ForumViriumHelsinki/.github/.github/workflows/`
- **Personal**: `/Users/lgates/repos/laurigates/.github/.github/workflows/`

## Steps

1. **Identify changed workflows upstream**
   - Check recent FVH commits touching `reusable-*.yml` files
   - Compare each shared workflow between both repos to find differences
   - Classify differences as: upstream improvement, personal enhancement, or cosmetic (org name)

2. **Review each difference**
   - For each upstream improvement, verify it's applicable to personal repos
   - For each personal enhancement, confirm it should be preserved
   - Flag any conflicts where both repos diverged on the same section

3. **Apply upstream improvements**
   - Port functional changes (bug fixes, new features, permission changes)
   - Preserve personal enhancements (plugin inputs, expanded aliases, org-specific refs)
   - Update org-specific references (e.g., `ForumViriumHelsinki` -> `laurigates` in examples/comments)

4. **Verify**
   - Ensure no `ForumViriumHelsinki` references leaked into personal workflows (except in cosmetic comments about upstream origin)
   - Validate YAML syntax

## Expected Cosmetic Differences (ignore these)

These differences are intentional and should NOT be synced:
- Organization name in example `uses:` lines (`laurigates/.github/...` vs `ForumViriumHelsinki/.github/...`)
- `certificate-identity-regexp` URLs in cosign verification
- Repository references in `reusable-sync-ai-rules.yml`

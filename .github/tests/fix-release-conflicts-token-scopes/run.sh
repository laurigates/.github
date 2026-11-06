#!/usr/bin/env bash
# reusable-fix-release-conflicts.yml closes the conflicted release-please PR,
# deletes its branch, then dispatches release-please with `gh workflow run`,
# all with one token: the App token, else RELEASE_PLEASE_TOKEN, else
# GITHUB_TOKEN. The workflow's `permissions:` block scopes GITHUB_TOKEN only,
# so an App or PAT without Actions: write closes the PR and then fails the
# dispatch, and nothing recreates the release PR (issue #114). This test pins
# that the input/secret descriptions and CLAUDE.md say the token needs
# actions write, and that the dispatch they describe still exists.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

WF=${1:-.github/workflows/reusable-fix-release-conflicts.yml}
NAME=fix-release-conflicts-token-scopes
n=0
fail() { echo "FAIL: $NAME: $*" >&2; exit 1; }

[ -f "$WF" ] || fail "workflow not found: $WF"

# 1. The dispatch the requirement exists for is still in a shipped step body.
runs=$(yq -r '.jobs[].steps[].run // ""' "$WF")
[ -n "$runs" ] || fail "no run: bodies extracted from $WF"
grep -Fq 'gh workflow run' <<<"$runs" \
  || fail "no step runs 'gh workflow run'; update this test if the dispatch moved"
n=$((n + 1))

# 2. The app-id input description names the actions permission.
app_desc=$(yq -r '.on.workflow_call.inputs."app-id".description // ""' "$WF")
[ -n "$app_desc" ] || fail "app-id input has no description"
grep -iq 'actions' <<<"$app_desc" \
  || fail "app-id description does not mention the Actions permission: $app_desc"
n=$((n + 1))

# 3. The RELEASE_PLEASE_TOKEN secret description names it too.
pat_desc=$(yq -r '.on.workflow_call.secrets.RELEASE_PLEASE_TOKEN.description // ""' "$WF")
[ -n "$pat_desc" ] || fail "RELEASE_PLEASE_TOKEN secret has no description"
grep -iq 'actions' <<<"$pat_desc" \
  || fail "RELEASE_PLEASE_TOKEN description does not mention the Actions permission: $pat_desc"
n=$((n + 1))

# 4. CLAUDE.md's bullet for the workflow states `actions: write`.
bullet=$(grep -F -- '- **`reusable-fix-release-conflicts.yml`**' CLAUDE.md || true)
[ -n "$bullet" ] || fail "CLAUDE.md has no reusable-fix-release-conflicts.yml bullet"
grep -Fq 'actions: write' <<<"$bullet" \
  || fail "CLAUDE.md reusable-fix-release-conflicts.yml bullet does not mention 'actions: write'"
n=$((n + 1))

echo "PASS: $NAME ($n assertion(s))"

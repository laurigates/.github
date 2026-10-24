#!/usr/bin/env bash
# Regression test: reusable-renovate.yml must not fall back to GITHUB_TOKEN
# silently.
#
# Without app-id the job used to run Renovate on GITHUB_TOKEN and stay green.
# In a repo where Actions may not create pull requests that identity cannot
# open a PR, its branches trigger no CI, and two laurigates repos ran it every
# four hours as a second Renovate beside the owner-wide App runner. The guard
# step fails the job unless the caller sets allow-github-token: true.
#
# Reads the shipped workflow with yq and runs the extracted guard body.
#
# Usage: bash .github/tests/renovate-token-guard/run.sh [workflow-file]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

NAME=renovate-token-guard
WORKFLOW="${1:-.github/workflows/reusable-renovate.yml}"
GUARD_STEP='Require an App token'
command -v yq >/dev/null || { echo "FATAL: yq (mikefarah) is required" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0
checks=0
fail() { printf '  FAIL %s\n' "$1"; failures=$((failures + 1)); }
ok()   { checks=$((checks + 1)); }

# The opt-in input exists and is off by default.
ok
[ "$(yq '.on.workflow_call.inputs.allow-github-token.type' "$WORKFLOW")" = boolean ] \
  || fail "input allow-github-token is missing or not a boolean"
ok
[ "$(yq '.on.workflow_call.inputs.allow-github-token.default' "$WORKFLOW")" = false ] \
  || fail "input allow-github-token must default to false"

# The guard runs exactly when app-id is empty and the caller has not opted in.
ok
got_if="$(STEP="$GUARD_STEP" yq '.jobs.renovate.steps[] | select(.name == strenv(STEP)) | .if // ""' "$WORKFLOW")"
[ "$got_if" = "inputs.app-id == '' && !inputs.allow-github-token" ] \
  || fail "'$GUARD_STEP' if: is '$got_if'"

# It precedes every step that can reach GITHUB_TOKEN. A guard after the
# Renovate step would fail the job only once the run had already happened.
names="$(yq -r '.jobs.renovate.steps[].name // ""' "$WORKFLOW")"
guard_at="$(grep -nxF -- "$GUARD_STEP" <<<"$names" | cut -d: -f1 || true)"
first_token="$(yq '[.jobs.renovate.steps[] | tojson | test("secrets\\.GITHUB_TOKEN")] | to_entries | map(select(.value)) | .[0].key // -1' "$WORKFLOW")"
ok
[ "$first_token" != -1 ] || fail "no step references secrets.GITHUB_TOKEN; the scan is not reading the job"
ok
if [ -z "$guard_at" ] || [ "$first_token" = -1 ] || [ "$((guard_at - 1))" -ge "$first_token" ]; then
  fail "'$GUARD_STEP' (step ${guard_at:-missing}) must come before the first GITHUB_TOKEN step (index $first_token)"
fi

# The body fails loudly.
STEP="$GUARD_STEP" yq '.jobs.renovate.steps[] | select(.name == strenv(STEP)) | .run // ""' "$WORKFLOW" > "$work/guard.sh"
rc=0
bash "$work/guard.sh" > "$work/out.txt" 2>&1 || rc=$?
ok
[ "$rc" -ne 0 ] || fail "the guard body exited 0"
ok
grep -q '^::error::app-id is empty' "$work/out.txt" || fail "the guard body prints no ::error:: naming app-id: $(head -c 200 "$work/out.txt")"
ok
# shellcheck disable=SC2016 # a literal ${{, not a shell expansion
if grep -qF '${{' "$work/guard.sh"; then fail "the guard body interpolates an expression"; fi

if [ "$failures" -ne 0 ]; then
  printf 'FAIL: %s (%d of %d assertion(s) failed)\n' "$NAME" "$failures" "$checks"
  exit 1
fi
printf 'PASS: %s (%d assertion(s))\n' "$NAME" "$checks"

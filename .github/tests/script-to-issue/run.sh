#!/usr/bin/env bash
# Regression tests for the script-to-issue composite action
# (.github/actions/script-to-issue), ported with the action from
# laurigates/claude-plugins:
#   - guard-test.sh: the duplicate-issue guard (guard.sh) against a stub gh,
#     the action's title/inputs step extracted and run, and the action's wiring
#     to the two scripts in its own directory (github.action_path, not the
#     caller's checkout);
#   - close-test.sh: close-superseded.sh against a stub gh.
#
# ACTION_DIR overrides the action directory under test.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
dir=".github/tests/script-to-issue"

total=0
for t in guard-test.sh close-test.sh; do
  out=$(bash "$dir/$t" 2>&1)
  rc=$?
  printf '%s\n' "$out"
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: $t exited $rc"
    exit 1
  fi
  if grep -q '^SKIP:' <<<"$out"; then
    echo "FAIL: $t skipped (jq missing); the suite asserts nothing without it"
    exit 1
  fi
  n=$(sed -n 's/^PASS=\([0-9]*\) FAIL=0$/\1/p' <<<"$out")
  if [ -z "$n" ] || [ "$n" -eq 0 ]; then
    echo "FAIL: $t printed no PASS=<n> FAIL=0 line"
    exit 1
  fi
  total=$((total + n))
done
echo "PASS: script-to-issue ($total assertion(s))"

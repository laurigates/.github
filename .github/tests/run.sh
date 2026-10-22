#!/usr/bin/env bash
# Discovery runner for this repo's workflow tests.
#
# Runs every .github/tests/<name>/run.sh in sorted order from the repo root,
# prints one line per test, and replays a failing test's output indented under
# its FAIL line. A test passes only if it exits 0 AND its last output line
# starts with "PASS: ". Exits 1 if any test fails, and also if no test is
# found: an empty run is green by construction and asserts nothing.
#
# Each test runs with stdin from /dev/null and fd 3 closed, and the list is
# read on fd 3. A test that reads its input (a stub CLI doing `cat > file`, a
# bare `jq`, `read`) would otherwise consume the remaining test names, end the
# loop early and report "All N passed" over a shorter list. The ran count is
# also checked against the discovered count, so a list that stops early for
# any other reason fails too.
#
# Usage: bash .github/tests/run.sh [name ...]   # no names = every test
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

tests=""
if [ "$#" -gt 0 ]; then
  for name in "$@"; do
    if [ ! -f ".github/tests/$name/run.sh" ]; then
      echo "ERROR: no test named '$name' (expected .github/tests/$name/run.sh)" >&2
      exit 1
    fi
    tests="$tests.github/tests/$name/run.sh
"
  done
else
  shopt -s nullglob
  for t in .github/tests/*/run.sh; do
    tests="$tests$t
"
  done
  shopt -u nullglob
  tests="$(printf '%s' "$tests" | LC_ALL=C sort)"
fi

if [ -z "$tests" ]; then
  echo "ERROR: discovered zero tests under .github/tests/*/run.sh; refusing to report a vacuous pass" >&2
  exit 1
fi

expected="$(printf '%s\n' "$tests" | grep -c .)"
total=0
failed=0
failed_names=""
while IFS= read -r t <&3; do
  [ -n "$t" ] || continue
  name="$(basename "$(dirname "$t")")"
  total=$((total + 1))
  rc=0
  out="$(bash "$t" </dev/null 3<&- 2>&1)" || rc=$?
  last="${out##*$'\n'}"
  if [ "$rc" -eq 0 ] && [ "${last#PASS: }" != "$last" ]; then
    printf 'PASS  %s  %s\n' "$name" "$last"
    continue
  fi
  failed=$((failed + 1))
  failed_names="$failed_names $name"
  if [ "$rc" -eq 0 ]; then
    # Exit 0 without the summary line: the test may have stopped before it
    # asserted anything, which is indistinguishable from a pass otherwise.
    printf 'FAIL  %s  (exit 0, but the last line is not "PASS: <name> (<n> assertion(s))")\n' "$name"
  else
    printf 'FAIL  %s  (exit %s)\n' "$name" "$rc"
  fi
  printf '%s\n' "$out" | sed 's/^/    | /'
done 3<<EOF
$tests
EOF

status=0
if [ "$failed" -gt 0 ]; then
  echo "$failed of $total test(s) failed:$failed_names"
  status=1
fi
if [ "$total" -ne "$expected" ]; then
  echo "ERROR: discovered $expected test(s) but ran $total; refusing to report a partial run as a pass" >&2
  status=1
fi
if [ "$status" -ne 0 ]; then
  exit "$status"
fi
echo "All $total test(s) passed."

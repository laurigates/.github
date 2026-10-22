#!/usr/bin/env bash
# Self-test for the discovery runner, .github/tests/run.sh.
#
# Copies the shipped runner (the file itself, not a retyped copy) into scratch
# git repos with fixture tests and checks that it cannot report a pass over a
# run that skipped, failed or never asserted anything. The case that motivated
# this: each test inherited the loop's stdin, which was the here-doc holding
# the remaining test names, so a test that read stdin (a stub `gh` doing
# `cat > file`) consumed the list and the runner printed "All 1 test(s)
# passed." with exit 0 while later failing tests never ran.
#
# Usage: bash .github/tests/runner/run.sh [runner]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

NAME=runner
RUNNER="${1:-.github/tests/run.sh}"
RUNNER="$(cd "$(dirname "$RUNNER")" && pwd)/$(basename "$RUNNER")"
[ -f "$RUNNER" ] || { echo "FAIL: $NAME: runner not found: $RUNNER" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

assertions=0
fail() {
  echo "FAIL: $NAME: $*" >&2
  exit 1
}

# new_repo <dir> [runner-file]: a scratch git repo holding the runner.
new_repo() {
  local dir="$1" src="${2:-$RUNNER}"
  mkdir -p "$dir/.github/tests"
  git -C "$dir" init -q
  cp "$src" "$dir/.github/tests/run.sh"
}

# add_test <dir> <name> <body>
add_test() {
  mkdir -p "$1/.github/tests/$2"
  printf '#!/usr/bin/env bash\n%s\n' "$3" >"$1/.github/tests/$2/run.sh"
}

# run_runner <dir> [names...]: sets rc and out. The runner's own stdin is a
# pipe with text in it, so a test that leaks onto it would also see input.
run_runner() {
  local dir="$1"
  shift
  rc=0
  out="$(cd "$dir" && printf 'stray\nstdin\n' | bash .github/tests/run.sh "$@" 2>&1)" || rc=$?
}

expect_rc() {
  [ "$rc" -eq "$1" ] || fail "$2: expected exit $1, got $rc; output:
$out"
  assertions=$((assertions + 1))
}

expect_line() {
  grep -Fxq -- "$1" <<<"$out" || fail "$2: missing line '$1'; output:
$out"
  assertions=$((assertions + 1))
}

expect_match() {
  grep -Eq -- "$1" <<<"$out" || fail "$2: no line matching /$1/; output:
$out"
  assertions=$((assertions + 1))
}

PASS_AAA='echo "PASS: aaa (1 assertion(s))"'

# 1. Tests that read stdin, or fd 3 (where the runner keeps the list), must
#    not swallow the tests after them; later failures must still be reported.
r="$work/stdin"
new_repo "$r"
add_test "$r" aaa "cat >/dev/null; $PASS_AAA"
add_test "$r" bbb 'exit 1'
add_test "$r" ccc 'read -r _ || true; cat <&3 >/dev/null 2>&1 || true; echo "PASS: ccc (1 assertion(s))"'
add_test "$r" ddd 'jq . >/dev/null 2>&1 || true; echo "PASS: ddd (1 assertion(s))"'
add_test "$r" zzz 'exit 1'
run_runner "$r"
expect_rc 1 "stdin readers"
expect_line "PASS  aaa  PASS: aaa (1 assertion(s))" "stdin readers"
expect_line "FAIL  bbb  (exit 1)" "stdin readers"
expect_line "PASS  ccc  PASS: ccc (1 assertion(s))" "stdin readers"
expect_line "PASS  ddd  PASS: ddd (1 assertion(s))" "stdin readers"
expect_line "FAIL  zzz  (exit 1)" "stdin readers"
expect_line "2 of 5 test(s) failed: bbb zzz" "stdin readers"

# 2. All green, with a stdin reader first: the count covers every test.
r="$work/green"
new_repo "$r"
add_test "$r" aaa "cat >/dev/null; $PASS_AAA"
add_test "$r" bbb 'echo "PASS: bbb (2 assertion(s))"'
run_runner "$r"
expect_rc 0 "all green"
expect_line "All 2 test(s) passed." "all green"

# 3. Exit 0 without a final PASS line is a failure.
r="$work/nopass"
new_repo "$r"
add_test "$r" aaa 'echo "looks fine"'
run_runner "$r"
expect_rc 1 "no PASS line"
expect_match '^FAIL  aaa  \(exit 0, but the last line is not ' "no PASS line"

# 4. Zero tests discovered is a failure, not a vacuous pass.
r="$work/empty"
new_repo "$r"
run_runner "$r"
expect_rc 1 "zero tests"
expect_match 'discovered zero tests' "zero tests"

# 5. Named selection runs only the named tests; an unknown name is an error.
r="$work/named"
new_repo "$r"
add_test "$r" aaa "$PASS_AAA"
add_test "$r" bbb 'exit 1'
run_runner "$r" aaa
expect_rc 0 "named"
expect_line "All 1 test(s) passed." "named"
run_runner "$r" nope
expect_rc 1 "unknown name"
expect_match "no test named 'nope'" "unknown name"

# 6. The ran-vs-discovered guard catches a list that stops early on its own.
#    Reintroduce a leak (the test inherits fd 3) in a scratch copy of the
#    runner and let a fixture drain fd 3: the loop ends after it, and only the
#    count check stands between that and "All 1 test(s) passed.".
leaky="$work/run.leaky.sh"
sed 's| 3<&-||' "$RUNNER" >"$leaky"
cmp -s "$RUNNER" "$leaky" && fail "count guard: could not reintroduce the fd 3 leak (runner changed shape?)"
r="$work/leak"
new_repo "$r" "$leaky"
add_test "$r" aaa "cat <&3 >/dev/null; $PASS_AAA"
add_test "$r" bbb 'exit 1'
run_runner "$r"
expect_rc 1 "count guard"
expect_match '^ERROR: discovered 2 test\(s\) but ran 1;' "count guard"

echo "PASS: $NAME ($assertions assertion(s))"

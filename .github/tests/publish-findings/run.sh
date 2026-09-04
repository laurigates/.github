#!/usr/bin/env bash
# Fixture harness for the shared publish block.
#
# It EXTRACTS the shipped step out of a workflow file and runs that. It never
# holds a retyped copy: a retyped copy is not the code under test, and every
# defect this harness has caught (annotation escaping, the non-object crash,
# the index() scope trap) was invisible to reading.
#
# Usage: bash .github/tests/publish-findings/run.sh [workflow-file]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

WORKFLOW="${1:-.github/workflows/reusable-security-owasp.yml}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# ---------------------------------------------------------------- extraction
# The `run:` body of the `Publish findings` step, dedented by its 10-space
# block-scalar indent. Terminates at the next step or step-level comment.
awk '
  /^      - name: Publish findings$/ { inpub = 1 }
  inpub && /^        run: \|$/       { inrun = 1; next }
  inrun && /^      [-#]/             { inrun = 0; inpub = 0 }
  inrun                              { print }
' "$WORKFLOW" | sed 's/^          //' > "$work/publish.sh"

if [ ! -s "$work/publish.sh" ]; then
  echo "FATAL: no 'Publish findings' run body extracted from $WORKFLOW" >&2
  exit 1
fi

# The guard is part of the contract the fixtures exercise (outcome-failure
# below only means anything while the guard admits a failed analysis), so it
# is asserted from the shipped text too.
GUARD="$(awk '
  /^      - name: Publish findings$/ { inpub = 1 }
  inpub && /^        if: /           { sub(/^        if: /, ""); print; exit }
' "$WORKFLOW")"
EXPECTED_GUARD="\${{ !cancelled() && steps.analyze.outcome != 'skipped' }}"

failures=0
checks=0

fail() { printf '  FAIL [%s] %s\n' "$CASE_NAME" "$1"; failures=$((failures + 1)); }
ok()   { checks=$((checks + 1)); }

assert_rc() {
  ok
  [ "$RC" = "$1" ] || fail "expected rc $1, got $RC"
}
assert_in() {
  ok
  grep -qF -- "$2" "$1" || fail "expected to find '$2' in $(basename "$1")"
}
assert_not_in() {
  ok
  grep -qF -- "$2" "$1" && fail "did NOT expect '$2' in $(basename "$1")" || true
}
assert_lines() {
  ok
  actual="$(grep -c -- "$2" "$1" || true)"
  [ "$actual" = "$3" ] || fail "expected $3 line(s) matching '$2' in $(basename "$1"), got $actual"
}

# run_case <name> <structured-output> <analyze-outcome> <blocking> <count-keys>
run_case() {
  CASE_NAME="$1"
  rm -rf "$work/run"
  mkdir -p "$work/run"
  export RUNNER_TEMP="$work/run"
  export GITHUB_STEP_SUMMARY="$work/run/summary.md"
  export GITHUB_OUTPUT="$work/run/output.txt"
  : > "$GITHUB_STEP_SUMMARY"
  : > "$GITHUB_OUTPUT"
  export TITLE='Test Analysis'
  export STRUCTURED_OUTPUT="$2"
  export ANALYZE_OUTCOME="$3"
  export BLOCKING_SEVERITIES="$4"
  export COUNT_KEYS="$5"
  set +e
  bash "$work/publish.sh" > "$work/run/annotations.txt" 2> "$work/run/stderr.txt"
  RC=$?
  set -e
  SUMMARY="$work/run/summary.md"
  OUTPUT="$work/run/output.txt"
  ANNOTATIONS="$work/run/annotations.txt"
}

echo "== publish-findings fixtures against $WORKFLOW"

# ------------------------------------------------------------------- guard
CASE_NAME="guard"
ok
[ "$GUARD" = "$EXPECTED_GUARD" ] || fail "publish guard is '$GUARD', expected '$EXPECTED_GUARD'"

# ------------------------------------------------------------------- happy
run_case happy \
  '{"total_issues":2,"critical_issues":1,"findings":[{"file":"src/low.ts","line":4,"severity":"Low","category":"A09","description":"minor"},{"file":"./src/crit.ts","line":10,"severity":"Critical","category":"A03","description":"bad","remediation":"fix it"}]}' \
  success 'Critical' 'total_issues,critical_issues'
assert_rc 0
assert_in "$SUMMARY" '## Test Analysis'
assert_in "$SUMMARY" '**total issues:** 2'
assert_in "$SUMMARY" '**critical issues:** 1'
assert_in "$SUMMARY" '### Critical — A03'
assert_in "$SUMMARY" '`src/crit.ts:10`'
assert_in "$SUMMARY" '**Remediation:** fix it'
# Blocking severities sort first and annotate at error level.
ok
head -1 "$ANNOTATIONS" | grep -qF '::error file=src/crit.ts,line=10::[Critical] [A03] bad' \
  || fail "first annotation is not the blocking one: $(head -1 "$ANNOTATIONS")"
assert_in "$ANNOTATIONS" '::warning file=src/low.ts,line=4::[Low] [A09] minor'
assert_in "$OUTPUT" 'blocking=1'
assert_in "$OUTPUT" 'itemised=2'
assert_in "$OUTPUT" 'count_total_issues=2'
assert_in "$OUTPUT" 'count_critical_issues=1'

# --------------------------------------------------------- empty findings
run_case empty-findings '{"total_issues":0,"critical_issues":0,"findings":[]}' success '' 'total_issues,critical_issues'
assert_rc 0
assert_in "$SUMMARY" 'No findings reported.'
assert_in "$SUMMARY" '**total issues:** 0'
assert_in "$OUTPUT" 'itemised=0'
assert_in "$OUTPUT" 'count_total_issues=0'

run_case no-findings-key '{"total_issues":0,"critical_issues":0}' success '' 'total_issues,critical_issues'
assert_rc 0
assert_in "$SUMMARY" 'No findings reported.'
assert_in "$OUTPUT" 'count_critical_issues=0'

# ------------------------------------------------------- unparseable input
run_case malformed-json 'not json at all' success '' 'total_issues,critical_issues'
assert_rc 0
assert_in "$SUMMARY" 'no parseable structured output'
assert_in "$OUTPUT" 'blocking=0'
assert_in "$OUTPUT" 'count_total_issues=0'
assert_in "$OUTPUT" 'count_critical_issues=0'

run_case empty-string '' success '' 'secrets_count'
assert_rc 0
assert_in "$SUMMARY" 'no parseable structured output'
assert_in "$OUTPUT" 'count_secrets_count=0'

run_case json-array-root '[1,2]' success '' 'total_issues'
assert_rc 0
assert_in "$SUMMARY" 'no parseable structured output'
assert_in "$OUTPUT" 'count_total_issues=0'

# ------------------------------------------------------ non-object element
run_case non-object-element \
  '{"total_issues":2,"findings":[{"file":"a.ts","severity":"Low","category":"C","description":"d"},"bare string",null,7]}' \
  success '' 'total_issues'
assert_rc 0
assert_in "$SUMMARY" '### Low — C'
assert_in "$OUTPUT" 'itemised=1'
assert_lines "$ANNOTATIONS" '^::' 1

# -------------------------------------------------------------- escaping
run_case escaping \
  '{"total_issues":1,"findings":[{"file":"src/a,b.ts","line":3,"severity":"High","category":"100% cat","description":"one\ntwo 50% x\rthree"}]}' \
  success '' 'total_issues'
assert_rc 0
assert_in "$ANNOTATIONS" 'file=src/a%2Cb.ts,line=3'
assert_in "$ANNOTATIONS" '%0A'
assert_in "$ANNOTATIONS" '%0D'
assert_in "$ANNOTATIONS" '50%25 x'
assert_in "$ANNOTATIONS" '[100%25 cat]'

# ------------------------------------------------------ missing file/line
run_case null-file '{"total_issues":1,"findings":[{"severity":"Low","category":"C","description":"d"}]}' success '' 'total_issues'
assert_rc 0
assert_in "$ANNOTATIONS" '::warning::[Low] [C] d'
assert_not_in "$ANNOTATIONS" 'file='

run_case empty-file '{"total_issues":1,"findings":[{"file":"","severity":"Low","category":"C","description":"d"}]}' success '' 'total_issues'
assert_rc 0
assert_in "$ANNOTATIONS" '::warning::[Low] [C] d'
assert_not_in "$ANNOTATIONS" 'file='

# ------------------------------------------------------- missing severity
run_case missing-severity \
  '{"total_issues":1,"findings":[{"file":"a.ts","category":"C","description":"d"}]}' \
  success 'Critical' 'total_issues'
assert_rc 0
assert_in "$SUMMARY" '### Unrated — C'
assert_in "$ANNOTATIONS" '::warning file=a.ts::[Unrated] [C] d'
assert_in "$OUTPUT" 'blocking=0'

# ---------------------------------------------------- count disagreement
run_case count-disagreement \
  '{"total_issues":7,"critical_issues":0,"findings":[{"file":"a.ts","severity":"Critical","category":"C","description":"d"},{"file":"b.ts","severity":"Low","category":"C","description":"d"}]}' \
  success 'Critical' 'total_issues,critical_issues'
assert_rc 0
assert_in "$OUTPUT" 'count_total_issues=7'
assert_in "$OUTPUT" 'count_critical_issues=0'
assert_in "$OUTPUT" 'itemised=2'
assert_in "$OUTPUT" 'blocking=1'

# -------------------------------------------------------- multi blocking
run_case multi-blocking \
  '{"total_vulnerabilities":3,"critical_high":2,"findings":[{"file":"p.json","severity":"Medium","category":"m","description":"d"},{"file":"p.json","severity":"High","category":"h","description":"d"},{"file":"p.json","severity":"Critical","category":"c","description":"d"}]}' \
  success 'Critical,High' 'total_vulnerabilities,critical_high'
assert_rc 0
assert_in "$OUTPUT" 'blocking=2'
assert_lines "$ANNOTATIONS" '^::error' 2
assert_lines "$ANNOTATIONS" '^::warning' 1

# --------------------------------------------------- alternate count shapes
run_case wcag-levels \
  '{"total_issues":2,"level_a_issues":1,"level_aa_issues":1,"findings":[]}' \
  success '' 'total_issues,level_a_issues,level_aa_issues'
assert_rc 0
assert_in "$SUMMARY" '**level a issues:** 1'
assert_in "$SUMMARY" '**level aa issues:** 1'
assert_in "$OUTPUT" 'count_level_aa_issues=1'

run_case secrets-single-count '{"secrets_count":0,"findings":[]}' success '' 'secrets_count'
assert_rc 0
assert_in "$SUMMARY" '**secrets count:** 0'
assert_in "$OUTPUT" 'count_secrets_count=0'

# ------------------------------------------------------------- over limit
OVER="$(jq -cn '{total_issues:14, findings:[range(14) | {file:"f\(.).ts", severity:"Low", category:"C", description:"d\(.)"}]}')"
run_case over-limit "$OVER" success '' 'total_issues'
assert_rc 0
assert_lines "$ANNOTATIONS" '^::warning' 10
assert_in "$ANNOTATIONS" '::notice::4 further finding(s) appear in the job summary only.'
assert_in "$OUTPUT" 'itemised=14'

# -------------------------------------------------------- outcome failure
run_case outcome-failure \
  '{"total_issues":1,"critical_issues":1,"findings":[{"file":"a.ts","severity":"Critical","category":"C","description":"d"}]}' \
  failure 'Critical' 'total_issues,critical_issues'
assert_rc 0
assert_in "$SUMMARY" "reported 'failure'; the findings below may be incomplete."
assert_in "$SUMMARY" '### Critical — C'
assert_in "$ANNOTATIONS" '::error file=a.ts::[Critical] [C] d'
assert_in "$OUTPUT" 'blocking=1'

# -------------------------------------------------------------- oversize
BIG="$(jq -cn --arg d "$(head -c 950000 /dev/zero | tr '\0' 'x')" '{total_issues:1, findings:[{file:"a.ts", severity:"Low", category:"C", description:$d}]}')"
run_case oversize "$BIG" success '' 'total_issues'
assert_rc 0
assert_in "$SUMMARY" '_Summary truncated at 900000 bytes; remaining findings omitted._'
ok
[ "$(wc -c < "$SUMMARY")" -lt 1048576 ] || fail "truncated summary is still over 1 MiB"

# ------------------------------------------------------------------ report
if [ "$failures" -eq 0 ]; then
  printf 'publish-findings: %d assertion(s) passed.\n' "$checks"
else
  printf 'publish-findings: %d assertion(s) FAILED out of %d.\n' "$failures" "$checks"
  exit 1
fi

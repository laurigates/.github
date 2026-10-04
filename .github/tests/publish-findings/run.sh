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

# The step's `env:` lines, verbatim (comments dropped). How the payload is
# WIRED is part of the contract: binding the model's output as an env string
# is the issue-#61 bug (an env string of MAX_ARG_STRLEN or more fails the
# execve of the step's own shell, so none of the block runs), and
# interpolating it into `run:` is the #57 injection. awk, not yq, so this
# harness keeps to awk/sed/jq.
ENV_LINES="$(awk '
  /^      - name: Publish findings$/ { inpub = 1 }
  inpub && /^        env:$/          { inenv = 1; next }
  inenv && /^        [^ ]/           { exit }
  inenv && /^          #/            { next }
  inenv                              { sub(/^          /, ""); print }
' "$WORKFLOW")"
EXPECTED_EXECUTION_FILE="EXECUTION_FILE: \${{ steps.analyze.outputs.execution_file }}"

# The bash this harness execs must never carry a string the kernel refuses
# (copy_strings() rejects any single argv/envp string >= MAX_ARG_STRLEN): a
# fixture that needed one would only prove the harness can exec, not that
# the block handles the payload.
MAX_ARG_STRLEN=131072

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

# Self-check, builtins only and in a subshell so LC_ALL=C (byte lengths) does
# not leak: an over-cap export would fail the exec with E2BIG, and the case
# would pass or fail for the wrong reason.
env_under_cap() (
  LC_ALL=C
  for v in $(compgen -e); do
    val="${!v}"
    if [ $(( ${#v} + 1 + ${#val} )) -ge "$MAX_ARG_STRLEN" ]; then
      echo "FATAL [$CASE_NAME]: the harness would exec with env string $v of ${#val} bytes, at or over MAX_ARG_STRLEN" >&2
      exit 1
    fi
  done
)

# run_case <name> <structured-output> <analyze-outcome> <blocking> <count-keys>
#
# The payload reaches the block the way production delivers it: inside the
# action's execution file, a JSON array of SDK messages whose last `result`
# message carries `structured_output`. Shell variables, set for one call and
# reset after it, shape that file:
#   EXEC_MODE      ''        wrap $2 as the result's structured_output:
#                            valid JSON as JSON, anything else as a JSON
#                            string, '' as a result with no such key
#                  verbatim  $2 IS the whole execution file
#                  missing   EXECUTION_FILE names a path that does not exist
#                  unset     EXECUTION_FILE is not set at all
#   RESULT_SUBTYPE / RESULT_IS_ERROR  the result message's subtype/is_error
#
# The payload goes to jq on stdin, never through --arg/--argjson: those are
# argv strings and hit the same MAX_ARG_STRLEN this harness exists to clear.
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
  export ANALYZE_OUTCOME="$3"
  export BLOCKING_SEVERITIES="$4"
  export COUNT_KEYS="$5"

  local exec_file="$work/run/exec.json"
  local sub="${RESULT_SUBTYPE:-success}" err="${RESULT_IS_ERROR:-false}"
  local wrap='[{type:"system",subtype:"init"},{type:"result",subtype:$sub,is_error:$err,num_turns:7,structured_output:.}]'
  case "${EXEC_MODE:-}" in
    verbatim) printf '%s' "$2" > "$exec_file" ;;
    missing | unset) ;;
    '')
      if [ -z "$2" ]; then
        jq -cn --arg sub "$sub" --argjson err "$err" \
          '[{type:"system",subtype:"init"},{type:"result",subtype:$sub,is_error:$err,num_turns:7}]' > "$exec_file"
      elif printf '%s' "$2" | jq empty >/dev/null 2>&1; then
        printf '%s' "$2" | jq -c --arg sub "$sub" --argjson err "$err" "$wrap" > "$exec_file"
      else
        printf '%s' "$2" | jq -Rsc --arg sub "$sub" --argjson err "$err" "$wrap" > "$exec_file"
      fi ;;
    *) echo "FATAL: unknown EXEC_MODE '$EXEC_MODE'" >&2; exit 2 ;;
  esac
  case "${EXEC_MODE:-}" in
    unset)   unset EXECUTION_FILE ;;
    missing) export EXECUTION_FILE="$work/run/no-such-execution-file.json" ;;
    *)       export EXECUTION_FILE="$exec_file" ;;
  esac
  EXEC_MODE='' RESULT_SUBTYPE='' RESULT_IS_ERROR=''

  env_under_cap || exit 2
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

# ------------------------------------------------------------------ wiring
# Issue #61: the payload travels as a file the action wrote, never as an env
# string, and nothing reaches the script body through `${{ }}`.
CASE_NAME="wiring"
ok
grep -qxF -- "$EXPECTED_EXECUTION_FILE" <<<"$ENV_LINES" \
  || fail "publish env does not bind '$EXPECTED_EXECUTION_FILE'"
ok
if grep -q 'STRUCTURED_OUTPUT\|structured_output' <<<"$ENV_LINES"; then
  fail "publish env still binds the structured output as an env string (issue #61): $(grep 'STRUCTURED_OUTPUT\|structured_output' <<<"$ENV_LINES")"
fi
ok
if grep -qF '${{' "$work/publish.sh"; then
  fail "publish run body interpolates an expression: $(grep -F '${{' "$work/publish.sh" | head -1)"
fi

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
assert_in "$SUMMARY" 'no usable structured output'
assert_in "$OUTPUT" 'blocking=0'
assert_in "$OUTPUT" 'count_total_issues=0'
assert_in "$OUTPUT" 'count_critical_issues=0'

run_case empty-string '' success '' 'secrets_count'
assert_rc 0
assert_in "$SUMMARY" 'no usable structured output'
assert_in "$OUTPUT" 'count_secrets_count=0'

run_case json-array-root '[1,2]' success '' 'total_issues'
assert_rc 0
assert_in "$SUMMARY" 'no usable structured output'
assert_in "$OUTPUT" 'count_total_issues=0'

# ------------------------------------------------- findings not an array
# A string here used to abort jq under `set -e`, taking the summary, the
# annotations and the counts with it. It must degrade to the same report as
# unparseable input.
run_case findings-not-array '{"total_issues":3,"findings":"none"}' success '' 'total_issues'
assert_rc 0
assert_in "$SUMMARY" 'no usable structured output'
assert_in "$OUTPUT" 'blocking=0'
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

# ------------------------------------------------- severity is untrusted
# The schema constrains severity with an enum, which the model is asked to
# honour and the runner does not enforce. A newline in it would close the
# annotation and let the rest be parsed as its own workflow command.
run_case severity-injection \
  '{"total_issues":1,"findings":[{"file":"a.ts","severity":"Low\n::error::INJECTED","category":"C","description":"d"}]}' \
  success '' 'total_issues'
assert_rc 0
assert_lines "$ANNOTATIONS" '^::' 1
assert_lines "$ANNOTATIONS" '^::error::INJECTED' 0
assert_in "$ANNOTATIONS" '[Low%0A::error::INJECTED]'

# ------------------------------------------------ count values are untrusted
# $GITHUB_OUTPUT is a key=value file: a newline in a count opens a second
# line, and `blocking` is exactly what a caller's gate reads.
run_case count-injection \
  '{"total_issues":"0\nblocking=99","critical_issues":2,"findings":[{"file":"a.ts","severity":"Critical","category":"C","description":"d"}]}' \
  success 'Critical' 'total_issues,critical_issues'
assert_rc 0
assert_in "$OUTPUT" 'blocking=1'
assert_not_in "$OUTPUT" 'blocking=99'
assert_in "$OUTPUT" 'count_total_issues=0'
assert_in "$OUTPUT" 'count_critical_issues=2'
assert_lines "$OUTPUT" '^blocking=' 1

# ------------------------------------------------------- unusable line
# `line` lands in the annotation's property list, where a string injects
# further properties and `0` is not a valid anchor. Both must degrade to an
# annotation with a file and no line, never to a corrupted one.
run_case line-not-integer \
  '{"total_issues":1,"findings":[{"file":"a.ts","line":"1,col=9,endLine=99","severity":"Low","category":"C","description":"d"}]}' \
  success '' 'total_issues'
assert_rc 0
assert_in "$ANNOTATIONS" '::warning file=a.ts::[Low] [C] d'
assert_not_in "$ANNOTATIONS" 'col=9'

run_case line-zero \
  '{"total_issues":1,"findings":[{"file":"a.ts","line":0,"severity":"Low","category":"C","description":"d"}]}' \
  success '' 'total_issues'
assert_rc 0
assert_in "$ANNOTATIONS" '::warning file=a.ts::[Low] [C] d'
assert_not_in "$ANNOTATIONS" 'line='

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

# ----------------------------------------------- failed-run recovery (#61)
# The action sets `structured_output` only on a clean success, but its
# execution file keeps the last `result` message on the failure path too.
# These are the two upstream failure shapes that still carry the payload: a
# result flagged is_error, and a success result the action rejects for
# overrunning --max-turns. Both must publish, flagged as possibly incomplete.
RECOVER='{"total_issues":2,"critical_issues":1,"findings":[{"file":"a.ts","line":3,"severity":"Critical","category":"C","description":"d"},{"file":"b.ts","severity":"Low","category":"L","description":"e"}]}'
RESULT_IS_ERROR=true run_case recover-is-error "$RECOVER" failure 'Critical' 'total_issues,critical_issues'
assert_rc 0
assert_in "$SUMMARY" "reported 'failure'; the findings below may be incomplete."
assert_in "$SUMMARY" '### Critical — C'
assert_in "$ANNOTATIONS" '::error file=a.ts,line=3::[Critical] [C] d'
assert_in "$OUTPUT" 'blocking=1'
assert_in "$OUTPUT" 'itemised=2'
assert_in "$OUTPUT" 'count_critical_issues=1'

run_case recover-over-max-turns "$RECOVER" failure 'Critical' 'total_issues,critical_issues'
assert_rc 0
assert_in "$SUMMARY" 'may be incomplete'
assert_in "$OUTPUT" 'blocking=1'
assert_in "$OUTPUT" 'count_total_issues=2'

# The LAST result message is the one that counts.
EXEC_MODE=verbatim run_case last-result-wins \
  '[{"type":"result","subtype":"success","is_error":false,"structured_output":{"total_issues":9,"findings":[]}},{"type":"assistant"},{"type":"result","subtype":"success","is_error":false,"structured_output":{"total_issues":1,"findings":[]}}]' \
  success '' 'total_issues'
assert_rc 0
assert_in "$OUTPUT" 'count_total_issues=1'

# Non-object elements beside a real result message are skipped, not fatal:
# without `objects`, `.type` on a string aborts jq, `|| :` empties the
# payload, and a usable transcript silently degrades.
EXEC_MODE=verbatim run_case non-object-beside-result \
  "[\"bare\",null,{\"type\":\"system\",\"subtype\":\"init\"},7,{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"structured_output\":$RECOVER}]" \
  success 'Critical' 'total_issues,critical_issues'
assert_rc 0
assert_not_in "$SUMMARY" 'no usable structured output'
assert_in "$OUTPUT" 'blocking=1'
assert_in "$OUTPUT" 'itemised=2'

# ------------------------------------------ unusable execution file (#61)
# Every shape degrades to the same loud report with zeroed counts, so a
# caller's numeric gate reads 0 rather than '' -- and the step never aborts.
assert_degraded() {
  assert_rc 0
  assert_in "$SUMMARY" 'no usable structured output'
  assert_lines "$ANNOTATIONS" '^::warning::' 1
  assert_in "$OUTPUT" 'blocking=0'
  assert_in "$OUTPUT" 'itemised=0'
  assert_in "$OUTPUT" 'count_total_issues=0'
  assert_in "$OUTPUT" 'count_critical_issues=0'
}
DEGRADE_KEYS='total_issues,critical_issues'

EXEC_MODE=unset run_case exec-file-unset "$RECOVER" failure 'Critical' "$DEGRADE_KEYS"
assert_degraded
assert_in "$SUMMARY" 'the action exposed no execution file'

EXEC_MODE=missing run_case exec-file-missing "$RECOVER" failure 'Critical' "$DEGRADE_KEYS"
assert_degraded
assert_in "$SUMMARY" 'the action exposed no execution file'

EXEC_MODE=verbatim run_case exec-file-not-json 'Error: this is not JSON {' failure 'Critical' "$DEGRADE_KEYS"
assert_degraded
assert_not_in "$SUMMARY" 'the action exposed no execution file'

EXEC_MODE=verbatim run_case exec-file-empty '' failure 'Critical' "$DEGRADE_KEYS"
assert_degraded

# An object whose VALUES are result messages: `.[]?` would iterate them and
# publish; only an array of messages is a transcript.
EXEC_MODE=verbatim run_case exec-file-object \
  "{\"r\":{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"structured_output\":$RECOVER}}" \
  success 'Critical' "$DEGRADE_KEYS"
assert_degraded

EXEC_MODE=verbatim run_case exec-file-no-result \
  "[{\"type\":\"system\",\"subtype\":\"init\"},{\"type\":\"assistant\",\"structured_output\":$RECOVER},\"bare\",null]" \
  failure 'Critical' "$DEGRADE_KEYS"
assert_degraded

RESULT_SUBTYPE=error_max_turns RESULT_IS_ERROR=true run_case exec-file-error-max-turns '' failure 'Critical' "$DEGRADE_KEYS"
assert_degraded

# -------------------------------------------------------------- oversize
# The payload used to reach the block as an ENVIRONMENT string, and Linux
# caps a single argv/env string at MAX_ARG_STRLEN (32 * 4096 = 131072
# bytes), so anything larger failed the execve of the step's own shell with
# E2BIG before line 1 ran: no summary, no annotations, no `blocking`, only
# `Argument list too long` (issue #61; the same cap took this harness red on
# CI run 33902497222 while macOS, which has no per-string cap, stayed green).
# The payload now travels as a file, so the cap binds only argv/env strings
# -- which is why these fixtures build payloads inside jq and hand them over
# on stdin, and why env_under_cap() guards every exec. SUMMARY_MAX_BYTES is
# now the real ceiling, and populated input reaches it.
#
# 20000 near-empty finding objects: 60 KB of JSON rendering to 1.1 MB.
CASE_NAME=oversize
BIG="$(jq -cn --argjson n 20000 '{total_issues:$n, findings:[range($n) | {}]}')"
run_case oversize "$BIG" success '' 'total_issues'
assert_rc 0
assert_in "$SUMMARY" '_Summary truncated at 900000 bytes; remaining findings omitted._'
ok
[ "$(wc -c < "$SUMMARY")" -lt 1048576 ] || fail "truncated summary is still over 1 MiB"

# Over the env cap and under the summary cap: must publish in full.
CASE_NAME=oversize-beyond-env-cap
WIDE="$(jq -cn '{total_issues:400, findings:[range(400) | {file:"src/f\(.).ts", line:(. + 1), severity:"Low", category:"C", description:("d\(.) " + ("x" * 600))}]}')"
ok
[ "$(printf '%s' "$WIDE" | wc -c)" -gt "$MAX_ARG_STRLEN" ] \
  || fail "fixture is only $(printf '%s' "$WIDE" | wc -c) bytes; it must exceed MAX_ARG_STRLEN to test issue #61"
run_case oversize-beyond-env-cap "$WIDE" success '' 'total_issues'
assert_rc 0
assert_in "$SUMMARY" '### Low — C'
assert_in "$SUMMARY" '`src/f399.ts:400`'
assert_not_in "$SUMMARY" 'Summary truncated'
assert_lines "$ANNOTATIONS" '^::warning file=' 10
assert_in "$ANNOTATIONS" '::notice::390 further finding(s) appear in the job summary only.'
assert_in "$OUTPUT" 'itemised=400'
assert_in "$OUTPUT" 'count_total_issues=400'
assert_lines "$OUTPUT" '^blocking=0$' 1

# Populated findings that render past SUMMARY_MAX_BYTES: the truncation
# branch reached by realistic input, not only by empty objects.
CASE_NAME=oversize-populated
HUGE="$(jq -cn '{total_issues:1500, findings:[range(1500) | {file:"src/f\(.).ts", severity:(if . % 3 == 0 then "High" else "Low" end), category:"C", description:("x" * 700), remediation:"fix"}]}')"
ok
[ "$(printf '%s' "$HUGE" | wc -c)" -gt 900000 ] \
  || fail "fixture is only $(printf '%s' "$HUGE" | wc -c) bytes"
run_case oversize-populated "$HUGE" success 'High' 'total_issues'
assert_rc 0
assert_in "$SUMMARY" '### High — C'
assert_in "$SUMMARY" '_Summary truncated at 900000 bytes; remaining findings omitted._'
assert_in "$ANNOTATIONS" '::warning::Test Analysis: job summary truncated at 900000 bytes.'
ok
[ "$(wc -c < "$SUMMARY")" -lt 1048576 ] || fail "truncated summary is still over 1 MiB"
assert_in "$OUTPUT" 'blocking=500'
assert_in "$OUTPUT" 'itemised=1500'

# ------------------------------------------------------------------ report
if [ "$failures" -eq 0 ]; then
  printf 'publish-findings: %d assertion(s) passed.\n' "$checks"
else
  printf 'publish-findings: %d assertion(s) FAILED out of %d.\n' "$failures" "$checks"
  exit 1
fi

#!/usr/bin/env bash
# Regression test for laurigates/.github#65 (upstream
# ForumViriumHelsinki/.github#115 §1): a Claude analysis run that succeeds but
# returns no structured_output must not fail the job, and every genuine
# failure must still fail it with the reason.
#
# Scans EVERY workflow that runs anthropics/claude-code-action with
# --json-schema (the class the action hard-fails on a missing
# structured_output), so a new analysis workflow that omits the handling is
# caught too. For each one it asserts that the analysis step carries
# `continue-on-error: true`, then EXTRACTS the shipped `Classify analysis
# outcome` step body and runs it against fixture execution files shaped like
# the ones the action writes (a JSON array of SDK messages). No retyped copy.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

NAME=analysis-verdict
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0
checks=0
fail() { printf '  FAIL [%s] %s\n' "$CASE" "$1"; failures=$((failures + 1)); }
ok()   { checks=$((checks + 1)); }

command -v jq >/dev/null || { echo "FATAL: jq is required" >&2; exit 1; }
command -v yq >/dev/null || { echo "FATAL: yq is required" >&2; exit 1; }

workflows=()
for f in .github/workflows/*.yml workflow-templates/*.yml; do
  [ -f "$f" ] || continue
  grep -q 'anthropics/claude-code-action@' "$f" || continue
  grep -q -- '--json-schema' "$f" || continue
  workflows+=("$f")
done
# An empty scan is green by construction and would pin nothing.
if [ "${#workflows[@]}" -eq 0 ]; then
  echo "FATAL: no workflow runs claude-code-action with --json-schema; the scan found nothing to check" >&2
  exit 1
fi

EXPECTED_GUARD="\${{ !cancelled() && steps.analyze.outcome != 'skipped' }}"

# fixture <file> <json>
fixture() { printf '%s' "$2" > "$work/$1"; }
INIT='{"type":"system","subtype":"init","session_id":"s"}'
ASSIST='{"type":"assistant","message":{"content":[{"type":"text","text":"done"}]}}'
fixture no-verdict.json "[$INIT,$ASSIST,{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"num_turns\":10,\"result\":\"ok\"}]"
fixture null-verdict.json "[$INIT,{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"num_turns\":9,\"structured_output\":null}]"
fixture verdict.json "[$INIT,{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"num_turns\":12,\"structured_output\":{\"total_issues\":0,\"findings\":[]}}]"
fixture is-error.json "[$INIT,{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":true,\"num_turns\":3,\"errors\":[\"API Error: 529 overloaded\"]}]"
fixture max-turns.json "[$INIT,{\"type\":\"result\",\"subtype\":\"error_max_turns\",\"is_error\":true,\"num_turns\":50,\"errors\":[]}]"
fixture max-budget.json "[$INIT,{\"type\":\"result\",\"subtype\":\"error_max_budget_usd\",\"is_error\":true,\"num_turns\":31,\"errors\":[]}]"
fixture during-exec.json "[$INIT,{\"type\":\"result\",\"subtype\":\"error_during_execution\",\"is_error\":true,\"num_turns\":4,\"errors\":[\"boom\\n::error::INJECTED\",\"100% gone\"]}]"
fixture weird-subtype.json "[$INIT,{\"type\":\"result\",\"subtype\":\"odd\\n::error::INJECTED\",\"is_error\":true,\"num_turns\":1}]"
fixture empty-subtype.json "[$INIT,{\"type\":\"result\",\"subtype\":\"\",\"is_error\":true,\"num_turns\":2}]"
fixture no-result.json "[$INIT,$ASSIST]"
fixture not-json.txt 'Error: this is not JSON'
fixture empty.json ''

# run_case <name> <outcome> <execution-file-or-empty>
run_case() {
  CASE="$WF_SHORT/$1"
  rm -rf "$work/run"
  mkdir -p "$work/run"
  export GITHUB_STEP_SUMMARY="$work/run/summary.md"
  : > "$GITHUB_STEP_SUMMARY"
  export TITLE='Test Analysis'
  export ANALYZE_OUTCOME="$2"
  if [ -n "$3" ]; then export EXECUTION_FILE="$work/$3"; else unset EXECUTION_FILE; fi
  set +e
  bash "$work/verdict.sh" > "$work/run/out.txt" 2> "$work/run/err.txt"
  RC=$?
  set -e
  OUT="$work/run/out.txt"
}
assert_rc()    { ok; [ "$RC" = "$1" ] || fail "expected rc $1, got $RC ($(head -c 300 "$OUT"; head -c 300 "$work/run/err.txt"))"; }
assert_in()    { ok; grep -qF -- "$2" "$1" || fail "expected '$2' in $(basename "$1"): $(head -c 400 "$1")"; }
assert_lines() { ok; local n; n="$(grep -c -- "$2" "$1" || true)"; [ "$n" = "$3" ] || fail "expected $3 line(s) matching '$2' in $(basename "$1"), got $n"; }

ref_body=""
for WF in "${workflows[@]}"; do
  WF_SHORT="$(basename "$WF" .yml)"
  CASE="$WF_SHORT/structure"

  # 1. The analysis step must not fail the job by itself.
  ok
  coe="$(yq '[.jobs.*.steps[] | select(.id == "analyze")] | .[0]."continue-on-error"' "$WF")"
  [ "$coe" = "true" ] || fail "the 'analyze' step has continue-on-error '$coe', expected true: the action's own throw on a missing structured_output fails the job"

  # 2. The shipped verdict step, extracted rather than retyped. Blank lines
  #    are held back until a non-blank one follows, so the separator before
  #    the next step does not make otherwise identical bodies differ.
  awk '
    /^      - name: Classify analysis outcome$/ { inv = 1 }
    inv && /^        run: \|$/                 { inrun = 1; next }
    inrun && /^      [-#]/                     { inrun = 0; inv = 0 }
    inrun && /^[[:space:]]*$/                  { blank = blank "\n"; next }
    inrun                                      { printf "%s%s\n", blank, $0; blank = "" }
  ' "$WF" | sed 's/^          //' > "$work/verdict.sh"
  ok
  if [ ! -s "$work/verdict.sh" ]; then
    fail "no 'Classify analysis outcome' step found: nothing decides whether a failed analysis step should fail the job"
    continue
  fi
  GUARD="$(awk '
    /^      - name: Classify analysis outcome$/ { inv = 1 }
    inv && /^        if: /                     { sub(/^        if: /, ""); print; exit }
  ' "$WF")"
  ok
  [ "$GUARD" = "$EXPECTED_GUARD" ] || fail "verdict guard is '$GUARD', expected '$EXPECTED_GUARD'"
  ok
  yq -e '[.jobs.*.steps[] | select(.id == "verdict")] | .[0].env.EXECUTION_FILE == "${{ steps.analyze.outputs.execution_file }}"' "$WF" >/dev/null 2>&1 \
    || fail "verdict step does not read EXECUTION_FILE from steps.analyze.outputs.execution_file"

  # 3. One behaviour across the set.
  ok
  if [ -z "$ref_body" ]; then
    ref_body="$work/ref-verdict.sh"
    cp "$work/verdict.sh" "$ref_body"
  elif ! diff -q "$ref_body" "$work/verdict.sh" >/dev/null; then
    fail "verdict step body differs from the one in ${workflows[0]}"
  fi

  # 4. What a caller sees on the warning path. The shipped publish step runs
  #    first (same guard) and degrades to zeroed counts, so the job ends green
  #    with every count output '0', not '': indistinguishable from a clean
  #    scan by `result` and counts alone. Pinned so the docs cannot drift.
  CASE="$WF_SHORT/caller-view"
  awk '
    /^      - name: Publish findings$/ { inpub = 1 }
    inpub && /^        run: \|$/       { inrun = 1; next }
    inrun && /^      [-#]/             { inrun = 0; inpub = 0 }
    inrun                              { print }
  ' "$WF" | sed 's/^          //' > "$work/publish.sh"
  ok
  if [ ! -s "$work/publish.sh" ]; then
    fail "no 'Publish findings' step found"
  else
    keys="$(yq '[.jobs.*.steps[] | select(.id == "publish")] | .[0].env.COUNT_KEYS' "$WF")"
    rm -rf "$work/pub" && mkdir -p "$work/pub"
    set +e
    GITHUB_OUTPUT="$work/pub/output" GITHUB_STEP_SUMMARY="$work/pub/summary.md" \
      STRUCTURED_OUTPUT='' ANALYZE_OUTCOME=failure TITLE='Test Analysis' \
      BLOCKING_SEVERITIES="$(yq '[.jobs.*.steps[] | select(.id == "publish")] | .[0].env.BLOCKING_SEVERITIES' "$WF")" \
      COUNT_KEYS="$keys" bash "$work/publish.sh" > "$work/pub/out.txt" 2>&1
    RC=$?
    set -e
    OUT="$work/pub/out.txt"
    assert_rc 0
    assert_in "$work/pub/output" 'blocking=0'
    for k in ${keys//,/ }; do
      assert_lines "$work/pub/output" "^count_${k}=0\$" 1
    done
  fi
  run_case caller-view-verdict failure no-verdict.json
  assert_rc 0

  # 5. Behaviour.
  run_case no-structured-output failure no-verdict.json
  assert_rc 0
  assert_lines "$OUT" '^::warning::' 1
  assert_lines "$OUT" '^::error' 0
  assert_in "$OUT" 'returned no structured output, so this run has no verdict'
  assert_in "$OUT" '(10 turns)'
  assert_in "$GITHUB_STEP_SUMMARY" 'no verdict'

  run_case null-structured-output failure null-verdict.json
  assert_rc 0
  assert_lines "$OUT" '^::warning::' 1

  run_case analysis-succeeded success verdict.json
  assert_rc 0
  assert_lines "$OUT" '^::' 0

  run_case output-present-but-step-failed failure verdict.json
  assert_rc 1
  assert_in "$OUT" 'the action failed the step anyway'

  run_case is-error failure is-error.json
  assert_rc 1
  assert_lines "$OUT" '^::error::' 1
  assert_in "$OUT" 'reported is_error'
  assert_in "$OUT" 'API Error: 529 overloaded'

  run_case error-max-turns failure max-turns.json
  assert_rc 1
  assert_in "$OUT" 'max-turns limit after 50 turns'

  run_case error-max-budget failure max-budget.json
  assert_rc 1
  assert_in "$OUT" 'max-budget-usd ceiling after 31 turns'

  run_case error-strings-escaped failure during-exec.json
  assert_rc 1
  assert_lines "$OUT" '^::' 1
  assert_lines "$OUT" '^::error::INJECTED' 0
  assert_in "$OUT" 'boom%0A::error::INJECTED; 100%25 gone'

  run_case subtype-sanitised failure weird-subtype.json
  assert_rc 1
  assert_lines "$OUT" '^::' 1
  assert_lines "$OUT" '^::error::INJECTED' 0

  # An empty @tsv field is collapsed by `read` (tab is IFS whitespace), which
  # would shift is_error into SUBTYPE and name the wrong subtype.
  run_case empty-subtype failure empty-subtype.json
  assert_rc 1
  assert_in "$OUT" "result subtype 'unknown' after 2 turns"

  run_case no-result-message failure no-result.json
  assert_rc 1
  assert_in "$OUT" 'never sent a result message'

  run_case no-execution-file failure ''
  assert_rc 1
  assert_in "$OUT" 'left no execution file'

  run_case empty-execution-file failure empty.json
  assert_rc 1
  assert_in "$OUT" 'left no execution file'

  run_case unparseable-execution-file failure not-json.txt
  assert_rc 1
  assert_in "$OUT" 'is not a JSON array of SDK messages'
done

if [ "$failures" -ne 0 ]; then
  printf 'FAIL: %s (%d of %d assertion(s) failed across %d workflow(s))\n' "$NAME" "$failures" "$checks" "${#workflows[@]}"
  exit 1
fi
printf 'PASS: %s (%d assertion(s))\n' "$NAME" "$checks"

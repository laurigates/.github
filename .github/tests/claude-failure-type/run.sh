#!/usr/bin/env bash
# Fixture harness for the failure path of reusable-claude.yml (issue #78).
#
# When the Claude step fails, 'Detect failure type' reads the action's
# execution file and writes subtype/num_turns/errors/type to $GITHUB_OUTPUT,
# and 'Post continuation comment on failure' turns those into a PR or issue
# comment. Both steps used to paste values into their script text with
# ${{ }}: the model-emitted structured_output into bash, and the SDK's error
# text into JavaScript string literals run with the job's github-token. A `'`
# in either closed the quote and the rest ran as code (the #57 shape).
#
# This harness checks that no script body in the job holds an expression,
# that every value arrives through env:, and then EXTRACTS the shipped step
# bodies with yq and runs them: the bash step against the execution files in
# fixtures/, and the github-script body under node with a stub `github`,
# chained to the bash step's real outputs. It never holds a retyped copy.
#
# Usage: bash .github/tests/claude-failure-type/run.sh [workflow-file]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

WORKFLOW="${1:-.github/workflows/reusable-claude.yml}"
# Absolute: the detect step runs from an empty directory.
FIXTURES="$PWD/.github/tests/claude-failure-type/fixtures"
JOB=claude

for tool in yq jq node; do
  command -v "$tool" >/dev/null || { echo "FATAL: $tool not found on PATH" >&2; exit 1; }
done
[ -f "$WORKFLOW" ] || { echo "FATAL: no workflow at $WORKFLOW" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

DETECT_STEP='Detect failure type'
COMMENT_STEP='Post continuation comment on failure'
# The outputs anthropics/claude-code-action@v1 declares in its action.yml.
# A `uses:` step writes no $GITHUB_OUTPUT line the scan below could find, so a
# reference to the action's outputs is checked against this copy instead.
ACTION_OUTPUTS=' execution_file branch_name github_token structured_output session_id '

failures=0
checks=0
CASE_NAME=setup

fail() { printf '  FAIL [%s] %s\n' "$CASE_NAME" "$1"; failures=$((failures + 1)); }
ok()   { checks=$((checks + 1)); }
assert_eq() { # <actual> <expected> <what>
  ok
  [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"
}
assert_contains() { # <haystack> <needle> <what>
  ok
  case "$1" in *"$2"*) ;; *) fail "$3: expected to contain '$2'" ;; esac
}
assert_lacks() { # <haystack> <needle> <what>
  ok
  case "$1" in *"$2"*) fail "$3: did NOT expect '$2'" ;; *) ;; esac
}

# ---------------------------------------------------------------- extraction
step_field() { # <step name> <yq path relative to the step>
  STEP="$1" J="$JOB" yq -r ".jobs[strenv(J)].steps[] | select(.name == strenv(STEP)) | ($2) // \"\"" "$WORKFLOW"
}

echo "== claude-failure-type against $WORKFLOW"

# ----------------------------------------------------------------- structure
CASE_NAME=structure
step_field "$DETECT_STEP" .run > "$work/detect.sh"
step_field "$COMMENT_STEP" .with.script > "$work/comment.js"
have_detect=0; have_comment=0
ok; if [ -s "$work/detect.sh" ]; then have_detect=1; else fail "no '$DETECT_STEP' step with a run: body"; fi
ok; if [ -s "$work/comment.js" ]; then have_comment=1; else fail "no '$COMMENT_STEP' step with a script"; fi
assert_eq "$(step_field "$DETECT_STEP" .id)" failure-type "'$DETECT_STEP' id"

# Every script body in the job reads its values from env:, never from ${{ }}
# inside the script: an expression is pasted into the text before bash or
# node parses it. Walked by index, not by name: a by-name lookup reads an
# unnamed step's body as '' and passes it.
CASE_NAME=no-inline-expressions
step_count="$(J="$JOB" yq -r '.jobs[strenv(J)].steps | length' "$WORKFLOW")"
run_seen=0; script_seen=0
for ((i = 0; i < step_count; i++)); do
  step="$(J="$JOB" I="$i" yq -o=json '.jobs[strenv(J)].steps[env(I)]' "$WORKFLOW")"
  label="$(jq -r --arg i "$i" '.name // "step #\($i)"' <<<"$step")"
  if [ "$(jq -r 'has("run")' <<<"$step")" = true ]; then
    run_seen=$((run_seen + 1))
    # shellcheck disable=SC2016 # a literal GitHub expression, not a shell one
    assert_lacks "$(jq -r '.run' <<<"$step")" '${{' "'$label' run body"
  fi
  if jq -e '(.uses // "") | startswith("actions/github-script@")' <<<"$step" >/dev/null; then
    script_seen=$((script_seen + 1))
    # shellcheck disable=SC2016 # a literal GitHub expression, not a shell one
    assert_lacks "$(jq -r '.with.script // ""' <<<"$step")" '${{' "'$label' github-script body"
  fi
done
ok; [ "$run_seen" -gt 0 ] || fail "found no run: steps; the scan is not reading the job"
ok; [ "$script_seen" -gt 0 ] || fail "found no github-script step; the scan is not reading the job"

# structured_output is the caller's --json-schema object, set by upstream
# only on a successful run, so a failure step has nothing to read there; and
# reading it inline was the injection. No expression may reference it.
CASE_NAME=structured-output
assert_lacks "$(cat "$WORKFLOW")" 'outputs.structured_output' "workflow"

CASE_NAME=wiring
while IFS='|' read -r step key want; do
  assert_eq "$(step_field "$step" ".env.$key")" "$want" "'$step' env $key"
done <<'WIRING'
Detect failure type|EXEC_FILE|${{ steps.claude.outputs.execution_file }}
Post continuation comment on failure|FAILURE_TYPE|${{ steps.failure-type.outputs.type }}
Post continuation comment on failure|NUM_TURNS|${{ steps.failure-type.outputs.num_turns }}
Post continuation comment on failure|ERRORS|${{ steps.failure-type.outputs.errors }}
Post continuation comment on failure|BRANCH_NAME|${{ steps.claude.outputs.branch_name }}
Post continuation comment on failure|SESSION_ID|${{ steps.claude.outputs.session_id }}
WIRING
assert_eq "$(step_field "$DETECT_STEP" .if)" "steps.claude.outcome == 'failure'" "'$DETECT_STEP' if:"
assert_eq "$(step_field "$COMMENT_STEP" .if)" "steps.claude.outcome == 'failure'" "'$COMMENT_STEP' if:"

# A mistyped `steps.<id>.outputs.<key>` is neither a YAML nor an actionlint
# error; it evaluates to '' at run time and the comment silently degrades.
# Every reference must name an EARLIER step with that id, which either is
# the claude-code-action step declaring <key> or a run: step that writes
# <key> to $GITHUB_OUTPUT (`echo "<key>=` or `echo "<key><<`).
CASE_NAME=output-refs
refs_report="$(J="$JOB" yq -o=json '.jobs[strenv(J)].steps' "$WORKFLOW" | jq -r --arg outs "$ACTION_OUTPUTS" '
  . as $s
  | [ range($s | length) as $i
      | ($s[$i] | tojson | [scan("steps\\.([A-Za-z0-9_-]+)\\.outputs\\.([A-Za-z0-9_-]+)")] | unique[]) as [$id, $key]
      | (first(range($i) | select($s[.].id == $id)) // null) as $d
      | { at: ($s[$i].name // "step #\($i)"), ref: "steps.\($id).outputs.\($key)",
          problem: (if $d == null then "no earlier step has id \($id)"
                    elif (($s[$d].uses // "") | startswith("anthropics/claude-code-action@"))
                    then (if ($outs | contains(" " + $key + " ")) then null
                          else "claude-code-action declares no output \($key)" end)
                    elif (($s[$d].run // "") | test("echo \"" + $key + "(=|<<)") | not)
                    then "step \($id) never writes \($key) to GITHUB_OUTPUT"
                    else null end) } ]
  | .[] | if .problem == null then "resolved|\(.at)|\(.ref)" else "unresolved|\(.at): \(.ref): \(.problem)" end')"
# Control: a reference the job must have. If the scan misses it, the scan is
# broken and an empty problem list below would mean nothing.
ok
grep -qxF "resolved|$COMMENT_STEP|steps.failure-type.outputs.type" <<<"$refs_report" \
  || fail "the scan did not resolve steps.failure-type.outputs.type in '$COMMENT_STEP'"
unresolved_refs="$(printf '%s\n' "$refs_report" | sed -n 's/^unresolved|//p')"
ok
if [ -n "$unresolved_refs" ]; then
  while IFS= read -r problem; do fail "$problem"; done <<<"$unresolved_refs"
fi

# ------------------------------------------------------------- detect step
# Runs the extracted body as the runner does (bash -e; pipefail is stricter
# still), from an empty directory and with only the variables env: binds.
run_detect() { # <exec file path or ''>
  rm -rf "$work/run"
  mkdir -p "$work/run/cwd"
  : > "$work/run/output"
  set +e
  (cd "$work/run/cwd" && env -i PATH="$PATH" HOME="$work/run" GITHUB_OUTPUT="$work/run/output" EXEC_FILE="$1" \
    bash --noprofile --norc -eo pipefail "$work/detect.sh" > "$work/run/stdout" 2> "$work/run/stderr")
  RC=$?
  set -e
  OUT_LINES="$(wc -l < "$work/run/output" | tr -d ' ')"
  OUT_KEYS="$(sed -n 's/^\([A-Za-z_][A-Za-z0-9_-]*\)\(=\|<<\).*/\1/p' "$work/run/output" | sort | tr '\n' ' ')"
  SUBTYPE="$(sed -n 's/^subtype=//p' "$work/run/output")"
  NUM_TURNS="$(sed -n 's/^num_turns=//p' "$work/run/output")"
  ERRORS="$(sed -n 's/^errors=//p' "$work/run/output")"
  TYPE="$(sed -n 's/^type=//p' "$work/run/output")"
}

# Exactly the four keys, once each, one line each: a newline in any value
# writes a second `key=value` line that can override `type` or `num_turns`.
assert_outputs_shape() {
  assert_eq "$RC" 0 "exit code (stderr: $(head -c 300 "$work/run/stderr"))"
  assert_eq "$OUT_KEYS" 'errors num_turns subtype type ' "GITHUB_OUTPUT keys"
  assert_eq "$OUT_LINES" 4 "GITHUB_OUTPUT line count"
  ok; [[ "$NUM_TURNS" =~ ^[0-9]+$ ]] || fail "num_turns '$NUM_TURNS' is not an integer"
}

# ------------------------------------------------------------ comment step
# github-script runs `script` as the body of an async function; this calls it
# the same way, with a stub `github` that records the comment, and with only
# the variables env: binds (plus PATH) in process.env.
cat > "$work/harness.js" <<'JS'
const fs = require('fs');
const [scriptPath, outPath] = process.argv.slice(2);
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const calls = [];
const github = { rest: { issues: { createComment: async (args) => { calls.push(args); return { data: {} }; } } } };
const context = {
  issue: { number: 42 }, payload: {}, serverUrl: 'https://github.example',
  repo: { owner: 'harness', repo: 'stub' }, runId: 123456789,
};
const core = { info() {}, warning() {}, error() {}, setFailed(m) { throw new Error(`setFailed: ${m}`); } };
const fn = new AsyncFunction('require', 'github', 'context', 'core', fs.readFileSync(scriptPath, 'utf8'));
fn(require, github, context, core)
  .then(() => fs.writeFileSync(outPath, JSON.stringify(calls)))
  .catch((e) => { console.error(e && e.stack || String(e)); process.exit(2); });
JS

run_comment() { # <type> <num_turns> <errors> <branch> <session>
  rm -f "$work/calls.json"
  set +e
  env -i PATH="$PATH" FAILURE_TYPE="$1" NUM_TURNS="$2" ERRORS="$3" BRANCH_NAME="$4" SESSION_ID="$5" \
    node "$work/harness.js" "$work/comment.js" "$work/calls.json" > "$work/node.out" 2> "$work/node.err"
  JS_RC=$?
  set -e
  CALL_COUNT="$(jq 'length' "$work/calls.json" 2>/dev/null || echo 0)"
  BODY="$(jq -r '.[0].body // ""' "$work/calls.json" 2>/dev/null || true)"
  ISSUE="$(jq -r '.[0].issue_number // ""' "$work/calls.json" 2>/dev/null || true)"
}
assert_one_comment() {
  assert_eq "$JS_RC" 0 "script exit (stderr: $(head -c 300 "$work/node.err"))"
  assert_eq "$CALL_COUNT" 1 "createComment calls"
  assert_eq "$ISSUE" 42 "commented issue"
  assert_contains "$BODY" '[View workflow run](https://github.example/harness/stub/actions/runs/123456789)' "comment body"
}

# ------------------------------------------------------------------- cases
if [ "$have_detect" = 1 ]; then
  CASE_NAME=max-turns
  run_detect "$FIXTURES/max-turns.json"
  assert_outputs_shape
  assert_eq "$SUBTYPE" error_max_turns "subtype"
  assert_eq "$TYPE" max-turns "type"
  assert_eq "$NUM_TURNS" 51 "num_turns"
  assert_eq "$ERRORS" '' "errors"
  if [ "$have_comment" = 1 ]; then
    run_comment "$TYPE" "$NUM_TURNS" "$ERRORS" 'claude/issue-42' 'sess-1'
    assert_one_comment
    assert_contains "$BODY" 'Claude ran out of turns** (used 51 turns)' "comment body"
    assert_contains "$BODY" 'Continue where you left off @claude' "comment body"
    # shellcheck disable=SC2016 # the backticks are Markdown
    assert_contains "$BODY" 'Partial work was pushed to branch `claude/issue-42`' "comment body"
    # shellcheck disable=SC2016 # the backticks are Markdown
    assert_contains "$BODY" '<sub>Session: `sess-1`</sub>' "comment body"
  fi

  # The SDK's error text is influenced by the run. A quote, a command
  # substitution and a template literal must arrive as text, and its
  # newlines must not forge a second output line.
  CASE_NAME=execution-error-hostile
  run_detect "$FIXTURES/execution-error-hostile.json"
  assert_outputs_shape
  assert_eq "$TYPE" execution-error "type"
  assert_eq "$NUM_TURNS" 7 "num_turns"
  # shellcheck disable=SC2016 # the payload is literal text
  assert_eq "$ERRORS" 'API Error: it'"'"'s $(id) and `id` and ${process.exit(3)} type=max-turns; second num_turns=999' "errors"
  if [ "$have_comment" = 1 ]; then
    run_comment "$TYPE" "$NUM_TURNS" "$ERRORS" '' 'sess-2'
    assert_one_comment
    assert_contains "$BODY" 'Claude encountered an error during execution** (after 7 turns)' "comment body"
    # shellcheck disable=SC2016 # the payload is literal text
    assert_contains "$BODY" 'it'"'"'s $(id) and `id` and ${process.exit(3)} type=max-turns' "comment body"
    assert_lacks "$BODY" 'Partial work was pushed' "comment body (no branch)"
  fi

  CASE_NAME=budget
  run_detect "$FIXTURES/budget.json"
  assert_outputs_shape
  assert_eq "$TYPE" budget-exceeded "type"
  assert_eq "$NUM_TURNS" 12 "num_turns"
  if [ "$have_comment" = 1 ]; then
    run_comment "$TYPE" "$NUM_TURNS" "$ERRORS" '' ''
    assert_one_comment
    assert_contains "$BODY" 'Claude exceeded its budget** (12 turns)' "comment body"
    assert_lacks "$BODY" 'Continue where you left off' "comment body (not recoverable)"
    assert_lacks "$BODY" 'Session:' "comment body (no session)"
  fi

  # The execution file was never written: no summary, and the comment points
  # at the logs instead of rendering a misleading error.
  CASE_NAME=missing-file
  run_detect "$work/does-not-exist.json"
  assert_outputs_shape
  assert_eq "$SUBTYPE" no-execution-file "subtype"
  assert_eq "$TYPE" error "type"
  assert_eq "$NUM_TURNS" 0 "num_turns"
  assert_eq "$ERRORS" '' "errors"
  if [ "$have_comment" = 1 ]; then
    run_comment "$TYPE" "$NUM_TURNS" "$ERRORS" '' ''
    assert_one_comment
    assert_contains "$BODY" 'No execution summary was produced. See the [workflow logs](https://github.example/harness/stub/actions/runs/123456789)' "comment body"
    assert_lacks "$BODY" 'Error:' "comment body"
  fi

  CASE_NAME=unset-exec-file
  run_detect ''
  assert_outputs_shape
  assert_eq "$SUBTYPE" no-execution-file "subtype"
  assert_eq "$TYPE" error "type"

  CASE_NAME=not-json
  run_detect "$FIXTURES/not-json.json"
  assert_outputs_shape
  assert_eq "$SUBTYPE" unknown "subtype"
  assert_eq "$TYPE" error "type"
  assert_eq "$NUM_TURNS" 0 "num_turns"
  assert_eq "$ERRORS" '' "errors"

  CASE_NAME=bad-num-turns
  run_detect "$FIXTURES/bad-num-turns.json"
  assert_outputs_shape
  assert_eq "$NUM_TURNS" 0 "num_turns"
  assert_eq "$TYPE" max-turns "type"
  assert_eq "$ERRORS" '' "errors"

  CASE_NAME=bad-subtype
  run_detect "$FIXTURES/bad-subtype.json"
  assert_outputs_shape
  assert_eq "$SUBTYPE" unknown "subtype"
  assert_eq "$TYPE" error "type"

  # The last result message decides, and a non-object element is skipped
  # rather than aborting the read.
  CASE_NAME=two-results
  run_detect "$FIXTURES/two-results.json"
  assert_outputs_shape
  assert_eq "$TYPE" execution-error "type"
  assert_eq "$NUM_TURNS" 4 "num_turns"
  assert_eq "$ERRORS" boom "errors"

  # The errors output reaches the comment step through env:. An env string
  # of 131072 bytes or more fails node's execve with E2BIG before line 1
  # (#61), so the detect step must bound it.
  CASE_NAME=long-errors
  # --rawfile, not --arg: an argument that size is itself an E2BIG.
  head -c 200000 /dev/zero | tr '\0' 'x' > "$work/long.txt"
  jq -n --rawfile e "$work/long.txt" \
    '[{"type": "result", "subtype": "error_during_execution", "num_turns": 2, "errors": [$e]}]' > "$work/long.json"
  run_detect "$work/long.json"
  assert_outputs_shape
  ok; [ "${#ERRORS}" -le 4096 ] || fail "errors is ${#ERRORS} bytes; it must be capped well below MAX_ARG_STRLEN"
  assert_contains "$ERRORS" 'xxxxxxxxxx' "errors"
  if [ "$have_comment" = 1 ]; then
    run_comment "$TYPE" "$NUM_TURNS" "$ERRORS" '' ''
    assert_one_comment
  fi

  # Default branch of the switch: an SDK error with text, under type=error.
  if [ "$have_comment" = 1 ]; then
    CASE_NAME=error-with-text
    run_comment error 0 "it's a \`quote\`" '' ''
    assert_one_comment
    assert_contains "$BODY" "Error: \`it's a \`quote\`\`" "comment body"
    assert_lacks "$BODY" 'No execution summary' "comment body"
  fi
fi

# -------------------------------------------------------------------- report
if [ "$failures" -eq 0 ]; then
  printf 'PASS: claude-failure-type (%d assertion(s))\n' "$checks"
else
  printf 'FAIL: claude-failure-type (%d of %d assertion(s) failed)\n' "$failures" "$checks"
  exit 1
fi

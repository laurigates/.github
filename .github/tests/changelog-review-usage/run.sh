#!/usr/bin/env bash
# Harness for the triage token-usage summary in reusable-changelog-review.yml
# (issue #54).
#
# The job log cannot show cache hits: with show_full_output off, the action
# logs only duration, turns, cost and denial count, and sanitizeModelUsage
# strips token counts from it on purpose. The action does, however, always
# write every SDK message to its `execution_file` output. The step under test
# reduces that file to numbers (a per-call table plus totals and the cache hit
# rate) in the job summary and a numbers-only JSON artifact, without turning on
# full output on a public workflow.
#
# This harness pins the wiring (the step runs after publish, cannot gate it,
# reads the file through env:, and the Claude step keeps full output off) and
# runs the EXTRACTED run: body against fixtures. It never holds a retyped copy.
#
# Usage: bash .github/tests/changelog-review-usage/run.sh [workflow-file]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

WORKFLOW="$(pwd)/${1:-.github/workflows/reusable-changelog-review.yml}"
FIXTURES="$(pwd)/.github/tests/changelog-review-usage/fixtures"

for tool in yq jq git; do
  command -v "$tool" >/dev/null || { echo "FATAL: $tool not found on PATH" >&2; exit 1; }
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

JOB=claude-triage
CLAUDE_STEP='Triage changelog into a tracking issue'
PUBLISH_STEP='Publish tracking issue and ratchet PR'
USAGE_STEP='Summarise triage token usage'
UPLOAD_STEP='Upload triage token usage'

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
assert_line() { # <haystack> <exact line> <what>
  ok
  grep -qxF -- "$2" <<<"$1" || fail "$3: expected the line '$2'"
}

# ---------------------------------------------------------------- extraction
step_field() { # <step name> <yq path relative to the step>
  STEP="$1" yq -r ".jobs[\"$JOB\"].steps[] | select(.name == strenv(STEP)) | ($2) // \"\"" "$WORKFLOW"
}

echo "== changelog-review-usage against $WORKFLOW"

# ----------------------------------------------------------------- structure
CASE_NAME=structure
names="$(yq -r ".jobs[\"$JOB\"].steps[].name // \"\"" "$WORKFLOW")"
pos() { printf '%s\n' "$names" | { grep -nxF -- "$1" || true; } | cut -d: -f1; }
p_claude="$(pos "$CLAUDE_STEP")"
p_publish="$(pos "$PUBLISH_STEP")"
p_usage="$(pos "$USAGE_STEP")"
p_upload="$(pos "$UPLOAD_STEP")"
ok; [ -n "$p_claude" ] || fail "no '$CLAUDE_STEP' step in job $JOB"
ok; [ -n "$p_publish" ] || fail "no '$PUBLISH_STEP' step in job $JOB"
ok; [ -n "$p_usage" ] || fail "no '$USAGE_STEP' step in job $JOB"
ok; [ -n "$p_upload" ] || fail "no '$UPLOAD_STEP' step in job $JOB"
# After publish: telemetry runs once publication is decided, so it cannot gate it.
ok
if [ -n "$p_usage" ] && [ -n "$p_publish" ] && [ "$p_usage" -le "$p_publish" ]; then
  fail "'$USAGE_STEP' must run after '$PUBLISH_STEP' (got $p_usage <= $p_publish)"
fi
ok
if [ -n "$p_usage" ] && [ -n "$p_upload" ] && [ "$p_upload" -le "$p_usage" ]; then
  fail "'$UPLOAD_STEP' must run after '$USAGE_STEP' (got $p_upload <= $p_usage)"
fi

assert_eq "$(step_field "$CLAUDE_STEP" .id)" triage "'$CLAUDE_STEP' id"

# Full output stays off on this public workflow: the summary is the opt-in to
# token counts, not show_full_output (whole transcript) or display_report
# (Claude-authored content).
for key in show_full_output display_report; do
  val="$(step_field "$CLAUDE_STEP" ".with.$key")"
  ok
  case "$val" in ''|false) ;; *) fail "'$CLAUDE_STEP' sets $key: '$val' (must be unset or 'false')" ;; esac
done

# Runs when triage or publish failed (max-turns is the case worth tuning), but
# not on cancel; never fails the job.
# shellcheck disable=SC2016 # literal GitHub expressions, not shell ones
for step in "$USAGE_STEP" "$UPLOAD_STEP"; do
  assert_eq "$(step_field "$step" '.if')" '${{ !cancelled() }}' "'$step' if:"
  assert_eq "$(step_field "$step" '."continue-on-error"')" true "'$step' continue-on-error"
done
# shellcheck disable=SC2016
assert_eq "$(step_field "$USAGE_STEP" .env.EXEC_FILE)" '${{ steps.triage.outputs.execution_file }}' "'$USAGE_STEP' env EXEC_FILE"

assert_contains "$(step_field "$UPLOAD_STEP" .uses)" 'actions/upload-artifact@' "'$UPLOAD_STEP' uses"
# Repo convention (CLAUDE.md, Action pinning): a full commit SHA plus a version
# comment, never a floating tag like @v4.
upload_uses="$(step_field "$UPLOAD_STEP" .uses)"
ok
[[ "$upload_uses" =~ ^actions/upload-artifact@[0-9a-f]{40}$ ]] \
  || fail "'$UPLOAD_STEP' uses: '$upload_uses' is not pinned to a full commit SHA"
upload_comment="$(STEP="$UPLOAD_STEP" yq -r ".jobs[\"$JOB\"].steps[] | select(.name == strenv(STEP)) | .uses | line_comment" "$WORKFLOW")"
ok
[[ "$upload_comment" =~ ^v[0-9]+(\.[0-9]+)*$ ]] \
  || fail "'$UPLOAD_STEP' uses: has no '# vX.Y.Z' version comment (got '$upload_comment')"
# shellcheck disable=SC2016
assert_eq "$(step_field "$UPLOAD_STEP" .with.path)" '${{ runner.temp }}/triage-usage.json' "'$UPLOAD_STEP' path"
assert_eq "$(step_field "$UPLOAD_STEP" .with.name)" changelog-triage-usage "'$UPLOAD_STEP' name"
assert_eq "$(step_field "$UPLOAD_STEP" '.with."if-no-files-found"')" ignore "'$UPLOAD_STEP' if-no-files-found"
assert_eq "$(step_field "$UPLOAD_STEP" '.with."retention-days"')" 90 "'$UPLOAD_STEP' retention-days"
# "Re-run failed jobs" re-uploads the same name in the same run: v4 and later
# answer 409 without overwrite.
assert_eq "$(step_field "$UPLOAD_STEP" .with.overwrite)" true "'$UPLOAD_STEP' overwrite"

# Every `steps.<id>.outputs.<key>` in the job must name an EARLIER step with
# that id. For a run: step, <key> must be written to $GITHUB_OUTPUT; for a
# uses: step the key is declared in the remote action.yml, which this harness
# cannot read, so it is pinned to an allowlist instead:
#   anthropics/claude-code-action  execution_file  (upstream action.yml:173)
CASE_NAME=output-refs
refs_report="$(yq -o=json ".jobs[\"$JOB\"].steps" "$WORKFLOW" | jq -r '
  {"anthropics/claude-code-action": ["execution_file"]} as $declared
  | . as $s
  | [ range($s | length) as $i
      | ($s[$i] | tojson | [scan("steps\\.([A-Za-z0-9_-]+)\\.outputs\\.([A-Za-z0-9_-]+)")] | unique[]) as [$id, $key]
      | (first(range($i) | select($s[.].id == $id)) // null) as $d
      | { at: $s[$i].name, ref: "steps.\($id).outputs.\($key)",
          problem: (if $d == null then "no earlier step has id \($id)"
                    elif $s[$d].uses then
                      (($s[$d].uses | sub("@.*$"; "")) as $a
                       | if ($declared[$a] // [] | index($key)) then null
                         else "\($a) is not known to declare output \($key)" end)
                    elif (($s[$d].run // "") | test("echo \"" + $key + "(=|<<)") | not)
                    then "step \($id) never writes \($key) to GITHUB_OUTPUT"
                    else null end) } ]
  | .[] | if .problem == null then "resolved|\(.at)|\(.ref)" else "unresolved|\(.at): \(.ref): \(.problem)" end')"
ok
grep -qxF "resolved|$USAGE_STEP|steps.triage.outputs.execution_file" <<<"$refs_report" \
  || fail "the scan did not resolve steps.triage.outputs.execution_file in '$USAGE_STEP'"
unresolved_refs="$(printf '%s\n' "$refs_report" | sed -n 's/^unresolved|//p')"
ok
if [ -n "$unresolved_refs" ]; then
  while IFS= read -r problem; do fail "$problem"; done <<<"$unresolved_refs"
fi

CASE_NAME=structure
step_field "$USAGE_STEP" .run > "$work/usage.sh"
ok; [ -s "$work/usage.sh" ] || fail "'$USAGE_STEP' has no run: body"
# shellcheck disable=SC2016 # a literal GitHub expression, not a shell one
assert_lacks "$(cat "$work/usage.sh")" '${{' "usage run body (inputs come from env:)"

if [ "$failures" -gt 0 ] || [ ! -s "$work/usage.sh" ]; then
  printf '\nFAILED: %d of %d checks (structure); behaviour not exercised\n' "$failures" "$checks"
  exit 1
fi

# ---------------------------------------------------------------- behaviour
# run_case <name> <exec-file value | ""> [fixture to place at the fallback path]
run_case() {
  CASE_NAME="$1"
  C="$work/case-$1"
  rm -rf "$C"
  mkdir -p "$C/temp" "$C/workspace"
  : > "$C/summary"
  if [ -n "${3:-}" ]; then cp "$FIXTURES/$3" "$C/temp/claude-execution-output.json"; fi
  set +e
  (
    cd "$C/workspace"
    env RUNNER_TEMP="$C/temp" GITHUB_STEP_SUMMARY="$C/summary" GITHUB_WORKSPACE="$C/workspace" \
      EXEC_FILE="$2" \
      bash --noprofile --norc -eo pipefail "$work/usage.sh"
  ) > "$C/stdout" 2> "$C/stderr"
  RC=$?
  set -e
  SUMMARY="$(cat "$C/summary")"
  OUT="$(cat "$C/stdout")"
  USAGE_JSON="$C/temp/triage-usage.json"
  assert_eq "$RC" 0 "exit code (stderr: $(tail -n 3 "$C/stderr" | tr '\n' ' '))"
  # Reads and writes $RUNNER_TEMP and the summary only: the publish step has
  # switched branches, and a file left in the workspace is a later step's input.
  assert_eq "$(find "$C/workspace" -mindepth 1 | head -n 5)" '' "workspace left untouched"
}
uj() { jq -r "$1" "$USAGE_JSON"; }
# Everything in the JSON artifact is a number, null, or a sanitised token.
assert_numbers_only() {
  ok
  local bad
  bad="$(jq -r '[paths(scalars) as $p | getpath($p) as $v
                 | select(($v | type) == "string" and ($v | test("^[A-Za-z0-9._-]*$") | not))
                 | "\($p | map(tostring) | join("."))"] | join(", ")' "$USAGE_JSON")"
  [ -z "$bad" ] || fail "triage-usage.json holds non-token strings at: $bad"
}
for_every_case() {
  assert_contains "$SUMMARY" '### Triage token usage' "summary heading"
  for leak in TRANSCRIPT_TEXT TOOL_RESULT_TEXT RESULT_TEXT msg_ toolu_; do
    assert_lacks "$SUMMARY" "$leak" "summary (no transcript content or raw ids)"
    assert_lacks "$(cat "$USAGE_JSON" 2>/dev/null)" "$leak" "triage-usage.json (no transcript content or raw ids)"
  done
  ok; [ -s "$USAGE_JSON" ] || fail "no triage-usage.json in RUNNER_TEMP"
  [ -s "$USAGE_JSON" ] && assert_numbers_only
}

# ------------------------------------------------------------ normal
run_case normal "$FIXTURES/normal.json"
for_every_case
assert_eq "$(uj .per_call.calls)" 3 "calls"
assert_line "$SUMMARY" '| 1 | main | claude-opus-4-5 | 10 | 1000 | 0 | 50 | 0.0 |' "row 1"
assert_line "$SUMMARY" '| 2 | main | claude-opus-4-5 | 5 | 200 | 1000 | 80 | 83.0 |' "row 2"
assert_line "$SUMMARY" '| 3 | main | claude-opus-4-5 | 3 | 100 | 1200 | 40 | 92.1 |' "row 3"
assert_line "$SUMMARY" '| **total** | 18 | 1300 | 2200 | 170 | 62.5 |' "totals row"
assert_contains "$SUMMARY" 'Cache hit rate: 62.5%' "headline hit rate"
assert_contains "$SUMMARY" 'modelUsage' "totals source"
assert_line "$SUMMARY" '| gap (modelUsage − per-call) | 0 | 0 | 0 | 0 | |' "gap row"
assert_eq "$(uj .totals_source)" modelUsage "totals_source"
assert_eq "$(uj .totals.hit_rate_pct)" 62.5 "JSON hit rate"
assert_eq "$(uj .num_turns)" 3 "JSON num_turns"
assert_eq "$(uj .total_cost_usd)" 0.1235 "JSON total_cost_usd (4 dp)"
assert_eq "$(uj .subtype)" success "JSON subtype"
assert_contains "$OUT" 'cache hit rate 62.5%' "log line"

# ------------------------------------------- one response split across blocks
run_case split-blocks "$FIXTURES/split-blocks.json"
for_every_case
assert_eq "$(uj .per_call.calls)" 1 "calls (two messages share one message.id)"
assert_eq "$(uj '.calls[0].output')" 120 "output (per-field max over the id)"
assert_line "$SUMMARY" '| 1 | main | claude-opus-4-5 | 7 | 500 | 300 | 120 | 37.2 |' "row 1"
assert_lacks "$SUMMARY" '| 2 |' "summary (no second call row)"

# --------------------------------------------------------- subagent + side calls
run_case subagent "$FIXTURES/subagent.json"
for_every_case
assert_eq "$(uj .per_call.main_calls)" 1 "main calls"
assert_eq "$(uj .per_call.subagent_calls)" 1 "subagent calls"
assert_line "$SUMMARY" '| 2 | subagent | claude-haiku-4-5 | 4 | 100 | 0 | 30 | 0.0 |' "subagent row"
assert_line "$SUMMARY" '| per-call sum (main) | 10 | 0 | 0 | 20 | 0.0 |' "main sum row"
assert_line "$SUMMARY" '| per-call sum (subagent) | 4 | 100 | 0 | 30 | 0.0 |' "subagent sum row"
assert_line "$SUMMARY" '| **total** | 314 | 100 | 0 | 70 | 0.0 |' "totals come from modelUsage"
assert_line "$SUMMARY" '| gap (modelUsage − per-call) | 300 | 0 | 0 | 20 | |' "gap row"
assert_line "$SUMMARY" '| `claude-haiku-4-5` | 304 | 100 | 0 | 50 | 0.0 |' "per-model row"
assert_eq "$(uj .gap.input)" 300 "JSON gap.input"

# ------------------------------------------------- result without modelUsage
run_case no-modelusage "$FIXTURES/no-modelusage.json"
for_every_case
assert_eq "$(uj .totals_source)" per-call "totals_source"
assert_line "$SUMMARY" '| **total** | 20 | 0 | 80 | 9 | 80.0 |' "totals fall back to the per-call sum"
assert_contains "$SUMMARY" 'no `modelUsage`' "fallback note"
assert_lacks "$SUMMARY" '| gap' "summary (no gap row without modelUsage)"

# ------------------------------------------------------ max turns exhausted
run_case max-turns "$FIXTURES/max-turns.json"
for_every_case
assert_contains "$SUMMARY" 'error_max_turns' "subtype"
assert_contains "$SUMMARY" 'turns 25' "num_turns"
assert_line "$SUMMARY" '| **total** | 8 | 4000 | 4000 | 60 | 50.0 |' "totals still render"
assert_contains "$SUMMARY" 'Cache hit rate: 50.0%' "headline hit rate"

# ----------------------------------------------- newline-delimited messages
run_case jsonl "$FIXTURES/jsonl.json"
for_every_case
assert_eq "$(uj .per_call.calls)" 1 "calls"
assert_line "$SUMMARY" '| **total** | 1 | 0 | 3 | 2 | 75.0 |' "totals"

# ----------------------------------------------------------- hostile values
run_case hostile "$FIXTURES/hostile.json"
for_every_case
# Sanitising keeps the letters of a hostile name but none of its structure:
# no pipe, newline, colon or markup survives, and message ids are never printed.
assert_lacks "$SUMMARY" 'INJECTED_ID' "summary (message ids are never printed)"
assert_lacks "$SUMMARY" '| 99 |' "summary (no injected row)"
assert_lacks "$SUMMARY" '::' "summary (no workflow command through subtype)"
assert_lacks "$SUMMARY" 'blocking' "summary (count injection)"
assert_contains "$SUMMARY" 'successerrorINJECTED' "subtype sanitised to a token"
assert_lacks "$SUMMARY" 'HOSTILE_TRANSCRIPT_TEXT' "summary"
assert_lacks "$OUT" '::error::' "stdout (no workflow command smuggled through subtype)"
assert_line "$SUMMARY" '| 1 | main | claudeopus99injectedrow | 2 | 0 | 0 | 0 | 0.0 |' "row 1 (coerced, sanitised)"
assert_line "$SUMMARY" '| 2 | main | claude-opus-4-5 | 0 | 0 | 0 | 0 | n/a |' "row 2 (usage not an object)"
assert_line "$SUMMARY" '| **total** | 2 | 0 | 0 | 0 | 0.0 |' "totals (non-numbers and negatives are 0)"
# Every table row: label/agent/model cells are tokens, count cells are integers.
ok
bad_rows="$(grep '^|' <<<"$SUMMARY" | grep -vE '^\| [^|]+ \|( [0-9-]+ \|){4} ?([0-9]+\.[0-9]|n/a)? \|$' \
  | grep -vE '^\| [0-9]+ \| (main|subagent) \| [A-Za-z0-9._-]+ \|( [0-9]+ \|){4} ([0-9]+\.[0-9]|n/a) \|$' \
  | grep -vE '^\|( ?-*:? ?\|)+$|^\| (#|Totals) \|' || true)"
[ -z "$bad_rows" ] || fail "table rows outside the expected shape: $bad_rows"
assert_eq "$(uj .num_turns)" null "JSON num_turns (string rejected)"
assert_eq "$(uj .total_cost_usd)" null "JSON total_cost_usd (string rejected)"
assert_eq "$(uj '.calls[0].output')" 0 "JSON output_tokens string coerced to 0"
assert_eq "$(uj '[.. | numbers | select(. < 0)] | length')" 0 "JSON (no negative counts outside the gap)"

# ----------------------------------------- more calls than the table holds
# Generated, not a fixture file: 205 distinct message ids, so the 200-row cap on
# the summary table (the step summary is capped at 1 MiB) is exercised. Call 1's
# model name is 100 characters, pinning the 64-character cap on names.
long_model="$(printf 'm%.0s' $(seq 100))"
jq -n --arg long "$long_model" '
  [ range(205) as $i
    | { type: "assistant", parent_tool_use_id: null,
        message: { id: "msg_cap_\($i)", model: (if $i == 0 then $long else "claude-opus-4-5" end),
                   usage: { input_tokens: 1, cache_creation_input_tokens: 0,
                            cache_read_input_tokens: 3, output_tokens: 2 } } } ]
  + [ { type: "result", subtype: "success", num_turns: 205 } ]' > "$work/many-calls.json"
run_case many-calls "$work/many-calls.json"
for_every_case
call_rows="$(grep -cE '^\| [0-9]+ \| (main|subagent) \|' <<<"$SUMMARY" || true)"
assert_eq "$call_rows" 200 "per-call rows in the summary (capped)"
assert_line "$SUMMARY" '| 200 | main | claude-opus-4-5 | 1 | 0 | 3 | 2 | 75.0 |' "last rendered row"
assert_lacks "$SUMMARY" '| 201 |' "summary (no row past the cap)"
assert_line "$SUMMARY" '_5 more calls in the `changelog-triage-usage` artifact._' "overflow note"
assert_eq "$(uj '.calls | length')" 205 "JSON keeps every call"
assert_eq "$(uj .per_call.calls)" 205 "JSON per_call.calls"
assert_eq "$(uj '.calls[204].seq')" 205 "JSON last seq"
assert_line "$SUMMARY" '| **total** | 205 | 0 | 615 | 410 | 75.0 |' "totals cover every call"
assert_eq "$(uj '.calls[0].model | length')" 64 "model name capped at 64 characters"

# ------------------------------------------------- no usage anywhere: warn
run_case zero-usage "$FIXTURES/zero-usage.json"
for_every_case
assert_contains "$OUT" '::warning::' "stdout warning"

# ----------------------------------------- EXEC_FILE empty, fallback present
run_case fallback "" normal.json
for_every_case
assert_eq "$(uj .per_call.calls)" 3 "calls read from the fallback path"

# ------------------------- EXEC_FILE names a missing file, fallback present
run_case stale-output "$work/does-not-exist.json" normal.json
for_every_case
assert_eq "$(uj .per_call.calls)" 3 "calls read from the fallback path"

# ----------------------------------------- EXEC_FILE empty, nothing to read
run_case missing ""
assert_contains "$OUT" '::notice::' "stdout notice"
assert_eq "$SUMMARY" '' "summary (nothing written)"
ok; [ ! -e "$USAGE_JSON" ] || fail "triage-usage.json written with no execution file"

# ------------------------------------------------------------ corrupt JSON
run_case corrupt "$FIXTURES/corrupt.json"
assert_contains "$OUT" '::warning::' "stdout warning"
ok; [ ! -e "$USAGE_JSON" ] || fail "triage-usage.json written from an unparseable file"

echo
if [ "$failures" -gt 0 ]; then
  printf 'FAILED: %d of %d checks\n' "$failures" "$checks"
  exit 1
fi
printf 'PASS: %d checks\n' "$checks"

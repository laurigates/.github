#!/usr/bin/env bash
# The single-quoted ${{ }} strings below are literal workflow expressions.
# shellcheck disable=SC2016
#
# Regression test for the opt-in `squash-message-check` job of
# reusable-enforce-conventional-commits.yml and the composite action it calls,
# .github/actions/squash-message-check.
#
# release-please drops a commit its conventional-commit parser throws on, and
# GitHub hard-wraps a PR description at 72 columns (outside column-0 fenced
# blocks, dropping the indentation of wrapped lines) when it builds the squash
# commit. A description that parses as written can therefore throw once
# wrapped. This test:
#   - runs the action's shipped install step (npm install of the parser alone;
#     needs network to the npm registry) and its shipped parse step against
#     fixture PR bodies, and asserts exit code, reported line number and line;
#   - pins the parser version to the one release-please-action's pin bundles;
#   - runs the workflow's shipped mode-validation and PR-read steps;
#   - runs the parse step with a title the parser rejects: the
#     description is still parsed and its error reported, and with
#     title-reported=true the title is a notice rather than a second error;
#   - checks the job wiring: `needs: fix-pr-title` with `!cancelled()` in the
#     job `if:` (a failed title check must not skip it), title-reported
#     taken from the fixer's result, the title read from the API rather than the
#     event payload, a fully qualified `uses:`, and no `${{` inside any run body.
#
# WORKFLOW / ACTION_DIR / RP_WORKFLOW override the files under test.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

NAME="squash-message-check"
WORKFLOW=${WORKFLOW:-.github/workflows/reusable-enforce-conventional-commits.yml}
ACTION_DIR=${ACTION_DIR:-.github/actions/squash-message-check}
RP_WORKFLOW=${RP_WORKFLOW:-.github/workflows/reusable-release-please.yml}
JOB="squash-message-check"
INSTALL_STEP="Install release-please's commit parser"
PARSE_STEP="Parse the squash commit message"
VALIDATE_STEP="Validate squash-message-check"
READ_STEP="Read the current PR title and body"
# release-please-action v4.4.1 resolves release-please 17.3.0, which bundles
# @conventional-commits/parser 0.4.1. Bump the three together.
EXPECTED_PARSER=0.4.1
EXPECTED_RP_ACTION=v4.4.1
SENTINEL=STUB-GH-5a9e17

fatal() { echo "FAIL: $NAME: $*"; exit 1; }
command -v yq >/dev/null || fatal "yq is required"
command -v jq >/dev/null || fatal "jq is required"
command -v node >/dev/null || fatal "node is required"
command -v npm >/dev/null || fatal "npm is required"

ACTION="$ACTION_DIR/action.yml"
[ -f "$WORKFLOW" ] || fatal "$WORKFLOW not found"
[ -f "$ACTION" ] || fatal "$ACTION not found"
[ -f "$ACTION_DIR/check.mjs" ] || fatal "$ACTION_DIR/check.mjs not found"
ACTION_ABS=$(cd "$ACTION_DIR" && pwd)

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

assertions=0
failures=0
CASE=setup
ok() { assertions=$((assertions + 1)); }
bad() { assertions=$((assertions + 1)); failures=$((failures + 1)); echo "  FAIL [$CASE] $*"; }
expect() { if [ "$1" = "$2" ]; then ok; else bad "$3: expected '$2', got '$1'"; fi; }
has() { if grep -Fq -- "$2" <<<"$1"; then ok; else bad "$3: missing '$2'"; fi; }
hasnt() { if grep -Fq -- "$2" <<<"$1"; then bad "$3: unexpected '$2'"; else ok; fi; }

# ------------------------------------------------------------ version pins
CASE=pins
parser_version=$(STEP="$INSTALL_STEP" yq -r '.runs.steps[] | select(.name == strenv(STEP)) | .env.PARSER_VERSION // ""' "$ACTION")
expect "$parser_version" "$EXPECTED_PARSER" "action.yml PARSER_VERSION"
rp_uses=$(grep -E 'uses:[[:space:]]*googleapis/release-please-action@' "$RP_WORKFLOW" || true)
[ "$(grep -c . <<<"$rp_uses")" = 1 ] || fatal "expected one release-please-action uses: line in $RP_WORKFLOW"
has "$rp_uses" "$EXPECTED_RP_ACTION" "release-please-action pin (bump PARSER_VERSION with it)"

# ------------------------------------------------------------ action steps
# Extract a step's run body and export its env (expressions dropped) into a
# script the harness runs under `bash -e`, as the runner runs `shell: bash`.
step_script() { # FILE YQ_STEPS_PATH STEP OUT
  local file=$1 path=$2 step=$3 out=$4
  [ "$(STEP="$step" yq "[$path | select(.name == strenv(STEP))] | length" "$file")" = 1 ] ||
    fatal "expected exactly one step named '$step' in $file"
  STEP="$step" yq -r "$path | select(.name == strenv(STEP)) | .run // \"\"" "$file" >"$out"
  [ -s "$out" ] || fatal "no run body for '$step' in $file"
}

CASE=action-contract
for step in "$INSTALL_STEP" "$PARSE_STEP"; do
  step_script "$ACTION" '.runs.steps[]' "$step" "$work/body"
  if grep -Fq '${{' "$work/body"; then bad "action step '$step' interpolates \${{ }} in its run body"; else ok; fi
  expect "$(STEP="$step" yq -r '.runs.steps[] | select(.name == strenv(STEP)) | .shell // ""' "$ACTION")" bash "shell of '$step'"
done
expect "$(yq -r '.runs.using' "$ACTION")" composite "runs.using"
for input in title body number mode title-reported; do
  expect "$(IN="$input" yq -r '.inputs | has(strenv(IN))' "$ACTION")" true "action declares input '$input'"
done
expect "$(yq -r '.inputs["title-reported"].default' "$ACTION")" false "title-reported defaults to false"
expect "$(STEP="$PARSE_STEP" yq -r '.runs.steps[] | select(.name == strenv(STEP)) | .env.TITLE_REPORTED // ""' "$ACTION")" \
  '${{ inputs.title-reported }}' "parse step passes title-reported as TITLE_REPORTED"

CASE=install
step_script "$ACTION" '.runs.steps[]' "$INSTALL_STEP" "$work/install.sh"
mkdir -p "$work/runner"
if ! out=$(RUNNER_TEMP="$work/runner" GITHUB_ACTION_PATH="$ACTION_ABS" PARSER_VERSION="$parser_version" \
  bash --noprofile --norc -e "$work/install.sh" 2>&1); then
  printf '%s\n' "$out" | tail -5
  fatal "the shipped install step failed (it needs network access to the npm registry)"
fi
ok
installed=$(find "$work/runner" -path '*node_modules/@conventional-commits/parser/package.json' | head -1)
[ -n "$installed" ] || fatal "install step left no @conventional-commits/parser under RUNNER_TEMP"
expect "$(jq -r .version "$installed")" "$EXPECTED_PARSER" "installed parser version"
check_mjs=$(find "$work/runner" -name check.mjs | head -1)
[ -n "$check_mjs" ] || fatal "install step did not copy check.mjs into RUNNER_TEMP"

step_script "$ACTION" '.runs.steps[]' "$PARSE_STEP" "$work/parse.sh"
# run_parse MODE TITLE BODY [TITLE_REPORTED]: sets rc, out, summary.
run_parse() {
  : >"$work/summary"
  rc=0
  out=$(cd "$work" && RUNNER_TEMP="$work/runner" GITHUB_ACTION_PATH="$ACTION_ABS" \
    GITHUB_STEP_SUMMARY="$work/summary" MODE="$1" PR_TITLE="$2" PR_BODY="$3" PR_NUMBER=12 \
    TITLE_REPORTED="${4:-false}" bash --noprofile --norc -e "$work/parse.sh" 2>&1) || rc=$?
  summary=$(cat "$work/summary")
}

TITLE='feat(api): add table export'
# Parses as written; GitHub's wrap puts `renderTable(rows, ...` at a line
# start with its parenthesis still open, and the parser reads that line as a
# footer and throws.
CALL_BODY="The export path now calls the shared helper, so the rendered output of renderTable(rows, { wide: true, sticky: false, header: true, footer: true, totals: true }) stays stable between runs."
CALL_LINE=4
CALL_TEXT='renderTable(rows, { wide: true, sticky: false, header: true, footer:'
FENCE_BODY=$'Example:\n\n```\n'"$CALL_BODY"$'\n```'
CLEAN_BODY='Adds a CSV export to the table view. The export uses the same column order as the screen.'
INDENT_BODY=$'- first item\n    - a nested list item that is long enough to wrap past seventy-two columns for sure'
INDENT_WRAPPED=$'- first item\n- a nested list item that is long enough to wrap past seventy-two\ncolumns for sure'

CASE=wrapped-call-error
run_parse error "$TITLE" "$CALL_BODY"
expect "$rc" 1 "exit code in error mode"
has "$out" "::error::" "error annotation"
has "$out" "line $CALL_LINE" "reported line number"
has "$out" "Line $CALL_LINE: $CALL_TEXT" "reported line text"
hasnt "$out" "::warning::" "no warning annotation in error mode"
has "$summary" "line $CALL_LINE" "job summary names the line"
has "$summary" "$CALL_TEXT" "job summary quotes the line"

CASE=wrapped-call-warn
run_parse warn "$TITLE" "$CALL_BODY"
expect "$rc" 0 "exit code in warn mode"
has "$out" "::warning::" "warning annotation"
hasnt "$out" "::error::" "no error annotation in warn mode"
has "$out" "Line $CALL_LINE: $CALL_TEXT" "reported line text"

CASE=fenced
run_parse error "$TITLE" "$FENCE_BODY"
expect "$rc" 0 "a column-0 fenced block is not wrapped, so the same text parses"
hasnt "$out" "::error::" "no error annotation"

CASE=clean
run_parse error "$TITLE" "$CLEAN_BODY"
expect "$rc" 0 "clean body exit code"
hasnt "$out" "::error::" "no error annotation"
hasnt "$out" "::warning::" "no warning annotation"

CASE=indented
run_parse error "$TITLE" "$INDENT_BODY"
expect "$rc" 0 "indented body exit code"

# A title the fixer cannot repair. The parser stops at its first error,
# so parsing the real message would report line 1 and never reach the body.
BAD_TITLE='Dashboard tweaks'
WRAP_HELP='GitHub wraps'
TITLE_HELP='conventional commit header'

CASE=bad-title-body-error-reported
run_parse error "$BAD_TITLE" "$CALL_BODY" true
expect "$rc" 1 "the body error still fails the job"
has "$out" "Line $CALL_LINE: $CALL_TEXT" "the body error is reported behind a bad title"
hasnt "$out" "at line 1:" "the reported title is not a second error"
has "$out" "::notice::" "notice that the title does not parse"
has "$out" "$WRAP_HELP" "wrap advice for the body error"
hasnt "$out" "$TITLE_HELP" "no title advice when the title is reported elsewhere"
has "$summary" "$CALL_TEXT" "job summary quotes the body line"

CASE=bad-title-clean-reported
run_parse error "$BAD_TITLE" "$CLEAN_BODY" true
expect "$rc" 0 "a reported title and a clean body pass"
hasnt "$out" "::error::" "no error annotation"
has "$out" "::notice::" "notice that the title does not parse"
hasnt "$out" "$WRAP_HELP" "no wrap advice for a clean body"
has "$summary" "placeholder title" "job summary says the body was parsed under a placeholder title"

CASE=bad-title-clean-unreported
run_parse error "$BAD_TITLE" "$CLEAN_BODY"
expect "$rc" 1 "an unreported bad title fails here"
has "$out" "at line 1:" "the title error"
has "$out" "$TITLE_HELP" "title advice"
hasnt "$out" "$WRAP_HELP" "no wrap advice when only the title fails"

CASE=bad-title-body-error-unreported
run_parse error "$BAD_TITLE" "$CALL_BODY"
expect "$rc" 1 "exit code"
has "$out" "at line 1:" "the title error"
has "$out" "Line $CALL_LINE: $CALL_TEXT" "and the body error, in one run"

CASE=bad-title-body-error-warn
run_parse warn "$BAD_TITLE" "$CALL_BODY" true
expect "$rc" 0 "warn mode exit code"
has "$out" "::warning::" "the body error is a warning"
has "$out" "Line $CALL_LINE: $CALL_TEXT" "body line"

CASE=bogus-mode
run_parse bogus "$TITLE" "$CLEAN_BODY"
[ "$rc" -ne 0 ] && ok || bad "check.mjs accepted MODE=bogus"

# The exported pure functions: the wrap model, and that the wrap (not the
# description as written) is what breaks the call fixture.
CASE=pure-functions
probe="$work/probe.mjs"
cat >"$probe" <<'JS'
const m = await import(process.env.CHECK_MJS)
const [, , fn] = process.argv
const pr = { title: process.env.T, number: 12, body: process.env.B }
if (fn === 'wrap') process.stdout.write(m.wrapBody(process.env.B))
if (fn === 'raw') process.stdout.write(JSON.stringify(m.parseErrors(`${pr.title} (#12)\n\n${pr.body}`)))
if (fn === 'squash') process.stdout.write(JSON.stringify(m.parseErrors(m.buildSquashMessage(pr))))
JS
pure() { CHECK_MJS="$check_mjs" T="$TITLE" B="$2" node "$probe" "$1"; }
expect "$(pure wrap "$INDENT_BODY")" "$INDENT_WRAPPED" "wrapBody drops the indentation of a wrapped line"
expect "$(pure wrap "$FENCE_BODY")" "$FENCE_BODY" "wrapBody leaves a column-0 fenced block alone"
expect "$(pure raw "$CALL_BODY")" "[]" "the call fixture parses as written"
squash=$(pure squash "$CALL_BODY")
expect "$(jq -r 'length' <<<"$squash")" 1 "the wrapped call fixture has one parse error"
expect "$(jq -r '.[0].line' <<<"$squash")" "$CALL_LINE" "parseErrors line"
expect "$(jq -r '.[0].text' <<<"$squash")" "$CALL_TEXT" "parseErrors text"

# ------------------------------------------------------------ workflow job
CASE=input
expect "$(yq -r '.on.workflow_call.inputs["squash-message-check"].type // ""' "$WORKFLOW")" string "input type"
expect "$(yq -r '.on.workflow_call.inputs["squash-message-check"].default // ""' "$WORKFLOW")" off "input default"

CASE=job-wiring
expect "$(yq -r ".jobs[\"$JOB\"] | has(\"needs\")" "$WORKFLOW")" true "job has needs"
needs=$(yq -r ".jobs[\"$JOB\"].needs | (select(tag == \"!!seq\") | join(\",\")) // ." "$WORKFLOW")
expect "$needs" fix-pr-title "needs"
job_if=$(yq -r ".jobs[\"$JOB\"].if // \"\"" "$WORKFLOW")
has "$job_if" "inputs.squash-message-check != 'off'" "job if"
# Without a status function, `needs` implies success(), so a title the
# fixer cannot repair skips the body check instead of reporting it.
has "$job_if" "!cancelled()" "job if runs the check when fix-pr-title fails"
expect "$(yq -r ".jobs[\"$JOB\"].runs-on" "$WORKFLOW")" ubuntu-slim "runs-on"
uses=$(yq -r ".jobs[\"$JOB\"].steps[] | select(has(\"uses\")) | .uses" "$WORKFLOW")
expect "$uses" "laurigates/.github/.github/actions/squash-message-check@main" "fully qualified uses"
for k in title body number mode; do
  v=$(K="$k" yq -r ".jobs[\"$JOB\"].steps[] | select(has(\"uses\")) | .with[strenv(K)] // \"\"" "$WORKFLOW")
  [ -n "$v" ] && ok || bad "uses step passes no '$k'"
  hasnt "$v" "github.event" "with.$k reads from the event payload"
done
has "$(yq -r ".jobs[\"$JOB\"].steps[] | select(has(\"uses\")) | .with.title" "$WORKFLOW")" "steps.pr.outputs" "title comes from the API read"
expect "$(yq -r ".jobs[\"$JOB\"].steps[] | select(has(\"uses\")) | .with[\"title-reported\"] // \"\"" "$WORKFLOW")" \
  "\${{ needs.fix-pr-title.result == 'failure' }}" "title-reported is the fixer's failure"
runs=$(yq -r ".jobs[\"$JOB\"].steps[] | .run // \"\"" "$WORKFLOW")
[ -n "$runs" ] || fatal "job $JOB has no run steps"
hasnt "$runs" '${{' "no \${{ }} inside a run body of job $JOB"

CASE=validate
step_script "$WORKFLOW" ".jobs[\"$JOB\"].steps[]" "$VALIDATE_STEP" "$work/validate.sh"
for pair in off:1 warn:0 error:0 bogus:1 :1; do
  mode=${pair%%:*} want=${pair##*:}
  rc=0
  MODE="$mode" bash --noprofile --norc -e "$work/validate.sh" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] && got=0 || got=1
  expect "$got" "$want" "validation of MODE='$mode'"
done

CASE=read-pr
step_script "$WORKFLOW" ".jobs[\"$JOB\"].steps[]" "$READ_STEP" "$work/read.sh"
has "$(cat "$work/read.sh")" 'gh api' "the PR is read through gh api"
mkdir -p "$work/bin"
cat >"$work/bin/gh" <<STUB
#!/usr/bin/env bash
echo "$SENTINEL \$*" >>"$work/gh.log"
case "\$*" in
  *"repos/org/app/pulls/12"*)
    jq -n '{number: 12, title: "feat: retitled by the fixer", body: "line one\nline two\n\nEOF\npr=forged"}' ;;
  *) echo "unexpected gh call: \$*" >&2; exit 1 ;;
esac
STUB
chmod +x "$work/bin/gh"
command -v "$work/bin/gh" >/dev/null || fatal "stub gh is not executable"
: >"$work/output"
rc=0
PATH="$work/bin:$PATH" GH_TOKEN=x REPO=org/app PR_NUMBER=12 GITHUB_OUTPUT="$work/output" \
  bash --noprofile --norc -e "$work/read.sh" >/dev/null 2>&1 || rc=$?
expect "$rc" 0 "read step exit code"
has "$(cat "$work/gh.log" 2>/dev/null || true)" "$SENTINEL" "stub gh was called"
expect "$(grep -c '^pr=' "$work/output")" 1 "exactly one pr= output line"
expect "$(grep -vc '^pr=' "$work/output" || true)" 0 "no other output lines (a body cannot forge one)"
pr_json=$(sed -n 's/^pr=//p' "$work/output")
expect "$(jq -r .title <<<"$pr_json")" "feat: retitled by the fixer" "title from the API"
expect "$(jq -r .body <<<"$pr_json")" $'line one\nline two\n\nEOF\npr=forged' "body from the API"
expect "$(jq -r .number <<<"$pr_json")" 12 "number from the API"

if [ "$failures" -gt 0 ]; then
  echo "FAIL: $NAME ($failures of $assertions assertion(s) failed)"
  exit 1
fi
echo "PASS: $NAME ($assertions assertion(s))"

#!/usr/bin/env bash
# shellcheck disable=SC2016 # single-quoted ${{ }} expressions are literal test data
# Regression test for the Claude cost guard (laurigates/gitops#341 item 4).
# The claude-config-sync App opens one PR per repo that touches only
# .claude/** and .mcp.json; reviewing ~45 of them spends Claude quota on
# nothing. Two places must skip them green, before checkout or Claude runs:
#
#   reusable-claude-review.yml  pull_request review
#   reusable-claude.yml         @claude mentions, when the event concerns a PR
#
# Both carry one `gate` step with an identical run: body. The test EXTRACTS
# that body with yq, runs it with a stub gh first on PATH (it logs a STUB-GH
# sentinel the test requires), and feeds it each workflow's own skip_authors
# and skip_paths defaults. It also checks the wiring: the gate runs before
# checkout, and checkout and the Claude step both require its output.
#
# reusable-auto-resolve-conflicts.yml must close a conflicting
# chore/claude-config-sync PR rather than have Claude resolve it; that case
# pattern is extracted and evaluated too.
#
# reusable-auto-fix.yml runs on workflow_run, whose pull_requests[] carries
# no author, so its own `gate` step (a different body: it resolves the PR
# from pr_number or the branch, then reads the author through the API) runs
# first, before the App token and checkout, and every later step requires
# its output (laurigates/.github#119). Its body is extracted and run the
# same way, against stub `pr list` and `api repos/.../pulls/N` calls.
#
# Usage: bash .github/tests/claude-cost-guard/run.sh
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

NAME=claude-cost-guard
for tool in yq jq; do
  command -v "$tool" >/dev/null || { echo "FATAL: $tool is required" >&2; exit 1; }
done
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0
checks=0
CASE=setup
fail() { printf '  FAIL [%s] %s\n' "$CASE" "$1"; failures=$((failures + 1)); }
ok()   { checks=$((checks + 1)); }
eq()   { ok; [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"; }
has()  { ok; grep -Fq -- "$2" "$1" 2>/dev/null || fail "$3: '$2' not in $(basename "$1"): $(head -c 400 "$1" 2>/dev/null | tr '\n' ' ')"; }
hasnt() { ok; if grep -Fq -- "$2" "$1" 2>/dev/null; then fail "$3: '$2' unexpectedly in $(basename "$1")"; fi; }
out_of() { sed -n "s/^$1=//p" "$2" | tail -n 1; }

GUARD="steps.gate.outputs.run == 'true'"
BOT='laurigates-claude-config-sync[bot]'

# ------------------------------------------------------------------ stubs
bin="$work/bin"
mkdir -p "$bin"
cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
printf 'STUB-GH %s\n' "$*" >> "$STUB_DIR/gh.log"
case "$*" in
  "api --paginate repos/"*"/pulls/"*"/files?per_page=100")
    [ "${GH_FAIL:-}" = 1 ] && { echo 'gh: Server Error (HTTP 502)' >&2; exit 1; }
    cat "$FX_FILES" ;;
  "pr list --repo "*" --head "*)
    [ "${GH_FAIL:-}" = 1 ] && { echo 'gh: Server Error (HTTP 502)' >&2; exit 1; }
    [ -z "${FX_PR:-}" ] || printf '%s\n' "$FX_PR" ;;
  "api repos/"*"/pulls/"*" --jq .user.login")
    [ "${GH_FAIL:-}" = 1 ] && { echo 'gh: Server Error (HTTP 502)' >&2; exit 1; }
    printf '%s\n' "$FX_AUTHOR" ;;
  *) echo "STUB-GH unexpected call: $*" >&2; exit 97 ;;
esac
STUB
chmod +x "$bin/gh"
CASE=stub
ok; [ "$(PATH="$bin:$PATH" STUB_DIR="$work" command -v gh)" = "$bin/gh" ] || fail "the gh stub is not first on PATH"

# files <fixture> <name>...: one page of GET /pulls/{n}/files, as gh
# --paginate prints it. Called in $( ), so the fixture name is passed in.
files() {
  local out="$work/fx-$1.json"
  shift
  printf '%s\n' "$@" | jq -R . | jq -s 'map({filename: ., status: "modified"})' > "$out"
  printf '%s' "$out"
}

# run_gate <body> <author> <pr> <files-fixture>: sets OUT, LOG, ANN and RC.
run_gate() {
  rm -rf "$work/run"
  mkdir -p "$work/run"
  OUT="$work/run/output"; LOG="$work/run/gh.log"; ANN="$work/run/stdout"
  : > "$OUT"; : > "$LOG"
  set +e
  PATH="$bin:$PATH" STUB_DIR="$work/run" FX_FILES="$4" GH_FAIL="${GH_FAIL:-}" \
    GITHUB_OUTPUT="$OUT" GH_TOKEN=stub REPO=laurigates/example PR="$3" AUTHOR="$2" \
    SKIP_AUTHORS="$SKIP_AUTHORS" SKIP_PATHS="$SKIP_PATHS" \
    bash "$1" > "$ANN" 2> "$work/run/stderr"
  RC=$?
  set -e
}
expect_skip() { # <reason fragment>
  eq "$RC" 0 "exit status ($(head -c 200 "$work/run/stderr"))"
  eq "$(out_of run "$OUT")" false "run output"
  has "$ANN" '::notice title=Claude skipped::' "skip notice"
  has "$ANN" "$1" "skip reason"
}
expect_run() {
  eq "$RC" 0 "exit status ($(head -c 200 "$work/run/stderr"))"
  eq "$(out_of run "$OUT")" true "run output"
  hasnt "$ANN" '::notice title=Claude skipped::' "no skip notice"
}

# ------------------------------------------------------------------ gate
ref_body=""
for spec in reusable-claude-review.yml:review reusable-claude.yml:claude; do
  WF=".github/workflows/${spec%%:*}"
  JOB="${spec##*:}"
  short="$(basename "$WF" .yml)"
  CASE="$short/extract"
  steps=".jobs.$JOB.steps"
  body="$work/$short-gate.sh"
  yq "${steps}[] | select(.id == \"gate\") | .run // \"\"" "$WF" > "$body"
  ok
  if [ ! -s "$body" ] || [ "$(cat "$body")" = "" ]; then
    fail "no step with id 'gate' and a run: body in $WF"
    continue
  fi
  ok
  if grep -qF '${{' "$body"; then fail "the gate's run body interpolates an expression; pass values through env:"; fi
  ok
  if [ -z "$ref_body" ]; then
    ref_body="$body"
  elif ! diff -q "$ref_body" "$body" >/dev/null; then
    fail "gate run body differs from the one in reusable-claude-review.yml"
  fi

  # ---- wiring
  CASE="$short/wiring"
  idx() { ID="$1" yq "[${steps}[]] | to_entries | map(select(.value.id == strenv(ID))) | .[0].key // -1" "$WF"; }
  i_gate="$(idx gate)"
  i_checkout="$(yq "[${steps}[]] | to_entries | map(select(.value.uses // \"\" | test(\"^actions/checkout@\"))) | .[0].key // -1" "$WF")"
  i_claude="$(yq "[${steps}[]] | to_entries | map(select(.value.uses // \"\" | test(\"^anthropics/claude-code-action@\"))) | .[0].key // -1" "$WF")"
  ok; [ "$i_gate" -ge 0 ] && [ "$i_gate" -lt "$i_checkout" ] && [ "$i_checkout" -lt "$i_claude" ] \
    || fail "step order must be gate < checkout < claude-code-action (got $i_gate $i_checkout $i_claude)"
  for i in "$i_checkout" "$i_claude"; do
    cond="$(yq "[${steps}[]] | .[$i].if // \"\"" "$WF")"
    ok
    case "$cond" in
      *"||"*) fail "step $i if: has || so the gate is not a hard precondition ('$cond')" ;;
      *"$GUARD"*) ;;
      *) fail "step $i does not require \"$GUARD\" ('$cond')" ;;
    esac
  done
  bind() { # <env var> <expected expression>
    ok
    got="$(K="$1" yq "${steps}[] | select(.id == \"gate\") | .env[strenv(K)] // \"\"" "$WF")"
    [ "$got" = "$2" ] || fail "gate env $1 is '$got', expected '$2'"
  }
  bind GH_TOKEN '${{ github.token }}'
  bind REPO '${{ github.repository }}'
  bind SKIP_AUTHORS '${{ inputs.skip_authors }}'
  bind SKIP_PATHS '${{ inputs.skip_paths }}'
  if [ "$JOB" = review ]; then
    bind PR '${{ github.event.pull_request.number }}'
    bind AUTHOR '${{ github.event.pull_request.user.login }}'
    # The release-please and github-actions[bot] job gate stays as it was.
    # One test per call: yq's `and` returned false with both sides true (actor-guard).
    for re in 'release-please--' 'github-actions\[bot\]'; do
      ok
      RE="$re" yq -e '.jobs.review.if | test(strenv(RE))' "$WF" >/dev/null 2>&1 \
        || fail "the review job's if: lost its '$re' clause"
    done
  else
    bind PR "\${{ github.event.pull_request.number || (github.event.issue.pull_request && github.event.issue.number) || '' }}"
    bind AUTHOR '${{ github.event.pull_request.user.login || github.event.issue.user.login }}'
    ok
    yq -e '.jobs.claude.if | test("github.event.sender.type != .Bot.")' "$WF" >/dev/null 2>&1 \
      || fail "the claude job's if: lost its sender.type != 'Bot' clause"
  fi

  # ---- defaults
  SKIP_AUTHORS="$(yq '.on.workflow_call.inputs.skip_authors.default // ""' "$WF")"
  SKIP_PATHS="$(yq '.on.workflow_call.inputs.skip_paths.default // ""' "$WF")"
  eq "$SKIP_AUTHORS" "$BOT" "skip_authors default"
  ok; grep -qxF '.claude/**' <<<"$SKIP_PATHS" || fail "skip_paths default lacks '.claude/**': '$SKIP_PATHS'"
  ok; grep -qxF '.mcp.json' <<<"$SKIP_PATHS" || fail "skip_paths default lacks '.mcp.json': '$SKIP_PATHS'"

  sync_only="$(files sync-only .claude/settings.json .mcp.json .claude/rules/deep/x.md)"
  mixed="$(files mixed .claude/settings.json .mcp.json src/app.ts)"
  code="$(files code src/app.ts README.md)"
  nested_mcp="$(files nested-mcp .claude/settings.json packages/a/.mcp.json)"
  # A rename lists the new path in filename and the old one in
  # previous_filename; the old path leaves the reviewed tree.
  rename_in="$work/fx-rename-in.json"
  jq -n '[{filename: ".claude/app.ts", previous_filename: "src/app.ts", status: "renamed"}]' > "$rename_in"
  rename_within="$work/fx-rename-within.json"
  jq -n '[{filename: ".claude/new.md", previous_filename: ".claude/old.md", status: "renamed"},
          {filename: ".mcp.json", status: "modified"}]' > "$rename_within"

  # ---- behaviour
  CASE="$short/author-skip"
  run_gate "$body" "$BOT" 7 "$code"
  expect_skip "the PR author '$BOT' is listed in skip_authors"
  ok; [ ! -s "$LOG" ] || fail "an author skip still listed the PR files: $(cat "$LOG")"

  CASE="$short/author-skip-case-insensitive"
  run_gate "$body" 'Laurigates-Claude-Config-Sync[bot]' 7 "$code"
  expect_skip "is listed in skip_authors"

  CASE="$short/paths-only-skip"
  run_gate "$body" laurigates 7 "$sync_only"
  expect_skip "every changed file (3) matches skip_paths"
  has "$LOG" 'STUB-GH api --paginate repos/laurigates/example/pulls/7/files?per_page=100' "PR files read through the API"

  CASE="$short/mixed-paths-run"
  run_gate "$body" laurigates 7 "$mixed"
  expect_run
  has "$LOG" 'STUB-GH api --paginate' "PR files read"

  CASE="$short/human-author-run"
  run_gate "$body" laurigates 7 "$code"
  expect_run

  CASE="$short/root-anchored-mcp"
  run_gate "$body" laurigates 7 "$nested_mcp"
  expect_run

  # Renaming code into .claude/ removes it from the reviewed tree.
  CASE="$short/rename-into-skip-paths-run"
  run_gate "$body" laurigates 7 "$rename_in"
  expect_run

  # A rename inside .claude/ stays a sync-only change, counted once.
  CASE="$short/rename-within-skip-paths-skip"
  run_gate "$body" laurigates 7 "$rename_within"
  expect_skip "every changed file (2) matches skip_paths"

  CASE="$short/other-bot-run"
  run_gate "$body" 'renovate[bot]' 7 "$code"
  expect_run

  # The files API lists at most 3000 files, so a list that long cannot
  # prove every file matched.
  CASE="$short/api-cap-run"
  cap="$work/cap.json"
  jq -n '[range(3000) | {filename: ".claude/f\(.).md"}]' > "$cap"
  run_gate "$body" laurigates 7 "$cap"
  expect_run

  CASE="$short/empty-skip-lists-run"
  SKIP_AUTHORS='' SKIP_PATHS='' run_gate "$body" "$BOT" 7 "$sync_only"
  expect_run

  CASE="$short/comma-separated-inputs"
  SKIP_AUTHORS="someone, $BOT" SKIP_PATHS='docs/*, .claude/**,.mcp.json' run_gate "$body" laurigates 7 "$sync_only"
  expect_skip "matches skip_paths"
  SKIP_AUTHORS="someone, $BOT" SKIP_PATHS='' run_gate "$body" "$BOT" 7 "$code"
  expect_skip "is listed in skip_authors"

  CASE="$short/api-failure-red"
  GH_FAIL=1 run_gate "$body" laurigates 7 "$code"
  ok; [ "$RC" -ne 0 ] || fail "a failed PR-files read must fail the step, not skip or run"
  ok; [ -z "$(out_of run "$OUT")" ] || fail "a failed read wrote run=$(out_of run "$OUT")"

  # Not a PR (an @claude on a plain issue): no checks, no API call.
  CASE="$short/not-a-pr-run"
  run_gate "$body" "$BOT" '' "$sync_only"
  expect_run
  ok; [ ! -s "$LOG" ] || fail "a non-PR event called gh: $(cat "$LOG")"

  CASE="$short/bad-pr-red"
  run_gate "$body" laurigates '7; id' "$code"
  ok; [ "$RC" -ne 0 ] || fail "a non-numeric PR number must fail the step"
done

# ------------------------------------------------------ auto-fix gate
AF=.github/workflows/reusable-auto-fix.yml
afsteps='.jobs["auto-fix"].steps'
CASE=auto-fix/extract
afbody="$work/auto-fix-gate.sh"
yq "${afsteps}[] | select(.id == \"gate\") | .run // \"\"" "$AF" > "$afbody"
ok
if [ ! -s "$afbody" ] || [ "$(cat "$afbody")" = "" ]; then
  fail "no step with id 'gate' and a run: body in $AF"
else
  ok
  if grep -qF '${{' "$afbody"; then fail "the auto-fix gate's run body interpolates an expression; pass values through env:"; fi

  # ---- wiring
  CASE=auto-fix/wiring
  i_gate="$(yq "[${afsteps}[]] | to_entries | map(select(.value.id == \"gate\")) | .[0].key // -1" "$AF")"
  eq "$i_gate" 0 "the gate is the job's first step (before the App token and checkout)"
  n_steps="$(yq "${afsteps} | length" "$AF")"
  ok; [ "$n_steps" -gt 1 ] || fail "auto-fix job has $n_steps step(s)"
  for ((i = 1; i < n_steps; i++)); do
    cond="$(yq "[${afsteps}[]] | .[$i].if // \"\"" "$AF")"
    name="$(yq "[${afsteps}[]] | .[$i].name // \"\"" "$AF")"
    ok
    case "$cond" in
      *"||"*) fail "step $i ($name) if: has || so the gate is not a hard precondition ('$cond')" ;;
      *"$GUARD"*) ;;
      *) fail "step $i ($name) does not require \"$GUARD\" ('$cond')" ;;
    esac
  done
  afbind() { # <env var> <expected expression>
    ok
    got="$(K="$1" yq "${afsteps}[] | select(.id == \"gate\") | .env[strenv(K)] // \"\"" "$AF")"
    [ "$got" = "$2" ] || fail "auto-fix gate env $1 is '$got', expected '$2'"
  }
  afbind GH_TOKEN '${{ github.token }}'
  afbind REPO '${{ github.repository }}'
  afbind BRANCH '${{ inputs.branch }}'
  afbind PR_NUMBER_INPUT '${{ inputs.pr_number }}'
  afbind SKIP_AUTHORS '${{ inputs.skip_authors }}'
  eq "$(yq '.on.workflow_call.inputs.skip_authors.default // ""' "$AF")" "$BOT" "auto-fix skip_authors default"
  # The actor gate stays as it was.
  ok
  yq -e '.jobs["auto-fix"].if | test("allowed_bots")' "$AF" >/dev/null 2>&1 \
    || fail "the auto-fix job's if: lost its allowed_bots actor clause"

  # run_af <branch> <pr_number input>: FX_PR / FX_AUTHOR / GH_FAIL / SKIP_AUTHORS
  # from the environment. Sets OUT, LOG, ANN and RC.
  run_af() {
    rm -rf "$work/run"
    mkdir -p "$work/run"
    OUT="$work/run/output"; LOG="$work/run/gh.log"; ANN="$work/run/stdout"
    : > "$OUT"; : > "$LOG"
    set +e
    PATH="$bin:$PATH" STUB_DIR="$work/run" FX_PR="${FX_PR:-}" FX_AUTHOR="${FX_AUTHOR:-}" \
      GH_FAIL="${GH_FAIL:-}" GITHUB_OUTPUT="$OUT" GH_TOKEN=stub REPO=laurigates/example \
      BRANCH="$1" PR_NUMBER_INPUT="$2" SKIP_AUTHORS="${SKIP_AUTHORS-$BOT}" \
      bash "$afbody" > "$ANN" 2> "$work/run/stderr"
    RC=$?
    set -e
  }
  af_skip() {
    eq "$RC" 0 "exit status ($(head -c 200 "$work/run/stderr"))"
    eq "$(out_of run "$OUT")" false "run output"
    has "$ANN" '::notice title=Auto-fix skipped::' "skip notice"
    has "$ANN" "$1" "skip reason"
  }
  af_run() {
    eq "$RC" 0 "exit status ($(head -c 200 "$work/run/stderr"))"
    eq "$(out_of run "$OUT")" true "run output"
    hasnt "$ANN" '::notice title=Auto-fix skipped::' "no skip notice"
  }

  # ---- behaviour
  CASE=auto-fix/listed-author-skip
  FX_PR=12 FX_AUTHOR="$BOT" run_af chore/claude-config-sync ''
  af_skip "the PR author '$BOT' is listed in skip_authors"
  has "$LOG" 'STUB-GH pr list --repo laurigates/example --head chore/claude-config-sync' "PR detected from the branch"
  has "$LOG" 'STUB-GH api repos/laurigates/example/pulls/12 --jq .user.login' "author read through the API"

  CASE=auto-fix/case-insensitive
  FX_PR=12 FX_AUTHOR='Laurigates-Claude-Config-Sync[bot]' run_af chore/claude-config-sync ''
  af_skip "is listed in skip_authors"

  CASE=auto-fix/human-author-run
  FX_PR=12 FX_AUTHOR=laurigates run_af feat/x ''
  af_run

  CASE=auto-fix/pr-number-input
  FX_PR=99 FX_AUTHOR="$BOT" run_af chore/claude-config-sync 34
  af_skip "is listed in skip_authors"
  hasnt "$LOG" 'STUB-GH pr list' "no PR lookup when pr_number is given"
  has "$LOG" 'STUB-GH api repos/laurigates/example/pulls/34 --jq .user.login' "author read for the given PR"

  CASE=auto-fix/no-pr-run
  FX_PR='' FX_AUTHOR="$BOT" run_af feat/no-pr ''
  af_run
  hasnt "$LOG" 'STUB-GH api repos/' "no author read without a PR"

  CASE=auto-fix/empty-skip-authors-run
  SKIP_AUTHORS='' FX_PR=12 FX_AUTHOR="$BOT" run_af chore/claude-config-sync ''
  af_run
  ok; [ ! -s "$LOG" ] || fail "skip_authors='' still called gh: $(cat "$LOG")"

  CASE=auto-fix/comma-separated
  SKIP_AUTHORS="someone, $BOT" FX_PR=12 FX_AUTHOR="$BOT" run_af chore/claude-config-sync ''
  af_skip "is listed in skip_authors"

  CASE=auto-fix/bad-pr-number-red
  FX_PR=12 FX_AUTHOR="$BOT" run_af feat/x '7; id'
  ok; [ "$RC" -ne 0 ] || fail "a non-numeric pr_number must fail the step"
  ok; [ -z "$(out_of run "$OUT")" ] || fail "a bad pr_number wrote run=$(out_of run "$OUT")"
  ok; [ ! -s "$LOG" ] || fail "a bad pr_number still called gh: $(cat "$LOG")"

  CASE=auto-fix/api-failure-red
  GH_FAIL=1 FX_PR=12 FX_AUTHOR="$BOT" run_af feat/x ''
  ok; [ "$RC" -ne 0 ] || fail "a failed PR lookup must fail the step, not skip or run"
  ok; [ -z "$(out_of run "$OUT")" ] || fail "a failed lookup wrote run=$(out_of run "$OUT")"
  GH_FAIL=1 FX_AUTHOR="$BOT" run_af feat/x 34
  ok; [ "$RC" -ne 0 ] || fail "a failed author read must fail the step, not skip or run"
  ok; [ -z "$(out_of run "$OUT")" ] || fail "a failed author read wrote run=$(out_of run "$OUT")"

  # A branch name is caller-controlled (issue #69): it reaches gh as one
  # argument and is never evaluated.
  CASE=auto-fix/hostile-branch
  hostile="x\$(touch $work/run/pwned)\`touch $work/run/pwned2\`"$'\n'"run=false"
  FX_PR=12 FX_AUTHOR=laurigates run_af "$hostile" ''
  af_run
  ok; [ ! -e "$work/run/pwned" ] && [ ! -e "$work/run/pwned2" ] || fail "the branch name was executed"
  has "$LOG" "--head x\$(touch" "hostile branch passed literally to gh"
  eq "$(grep -c '^run=' "$OUT")" 1 "exactly one run= line in GITHUB_OUTPUT"

  # A login that is not a login shape is sanitised before the notice.
  CASE=auto-fix/sanitised-author
  SKIP_AUTHORS="$BOT" FX_PR=12 FX_AUTHOR=$'laurigates-claude-config-sync[bot]%0A::error::x' run_af feat/x ''
  af_run
  hasnt "$ANN" '::error::' "workflow command injected through the author"
fi

# ------------------------------------------------- auto-resolve close list
CASE=auto-resolve/close-list
AR=.github/workflows/reusable-auto-resolve-conflicts.yml
yq '.jobs["find-conflicts"].steps[].run // ""' "$AR" > "$work/find.sh"
pattern="$(grep -E '^[[:space:]]*[^#(]*renovate/\*[^)]*\)' "$work/find.sh" | head -n 1 | sed -E 's/^[[:space:]]*//; s/\)[[:space:]]*$//')"
ok; [ -n "$pattern" ] || fail "no case pattern listing renovate/* in the find-conflicts step"
closes() { eval "case \"\$1\" in $pattern) return 0 ;; esac"; return 1; }
for b in chore/claude-config-sync renovate/x dependabot/npm/y; do
  ok; closes "$b" || fail "find-conflicts resolves '$b' with Claude instead of closing it"
done
for b in feat/claude-config-sync-thing chore/claude-config-sync-2 fix/x; do
  ok; if closes "$b"; then fail "find-conflicts closes '$b', which is not a recreated automated branch"; fi
done

if [ "$failures" -ne 0 ]; then
  printf 'FAIL: %s (%d of %d assertion(s) failed)\n' "$NAME" "$failures" "$checks"
  exit 1
fi
printf 'PASS: %s (%d assertion(s))\n' "$NAME" "$checks"

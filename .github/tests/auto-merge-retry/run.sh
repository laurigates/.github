#!/usr/bin/env bash
# The single-quoted ${{ }} strings below are literal workflow expressions.
# shellcheck disable=SC2016
#
# Regression test: the "Enable auto-merge" step of
# reusable-auto-merge-image-updater.yml must survive a sibling image-updater PR
# moving `main` between gh's mergeability read and its merge mutation
# ("Base branch was modified. Review and try the merge again.").
#
# It EXTRACTS the shipped `run:` body with yq and executes that under the shell
# GitHub uses for a step with no `shell:` (`bash -e {0}`), with stub `gh` and
# `sleep` first on PATH. It never holds a retyped copy of the step.
#
# It also scans every workflow and workflow template for other steps that merge
# a PR (`gh pr merge`, the REST merge endpoint, the `mergePullRequest`
# mutation). Each one is exposed to the same race, so each must be listed in
# ALLOWED below and exercised by the scenarios in this file.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

NAME=auto-merge-retry
WORKFLOW=.github/workflows/reusable-auto-merge-image-updater.yml
STEP="Enable auto-merge"
ALLOWED=("$WORKFLOW|$STEP")
SENTINEL=STUB-GH-7f3a9c

fatal() { echo "FATAL: $*" >&2; exit 1; }
command -v yq >/dev/null || fatal "yq is required (mikefarah/yq v4)"
command -v jq >/dev/null || fatal "jq is required (the stub gh applies --jq with it)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0
checks=0
CASE=setup
fail() { printf '  FAIL [%s] %s\n' "$CASE" "$1"; failures=$((failures + 1)); }
check() { checks=$((checks + 1)); }

# ---------------------------------------------------------------- extraction
step_q=".jobs[].steps[] | select(.name == \"$STEP\")"
[ "$(yq "[$step_q] | length" "$WORKFLOW")" = 1 ] ||
  fatal "expected exactly one '$STEP' step in $WORKFLOW"
yq -r "$step_q | .run" "$WORKFLOW" > "$work/body.raw"
[ -s "$work/body.raw" ] || fatal "no '$STEP' run body extracted from $WORKFLOW"

# The body is executed with `bash -e`, which is what the runner uses for a step
# without `shell:` and without a job/workflow `defaults.run.shell`.
if [ "$(yq "$step_q | .shell // \"\"" "$WORKFLOW")" != "" ] ||
   [ "$(yq '[.. | select(tag == "!!map" and has("defaults"))] | length' "$WORKFLOW")" != 0 ]; then
  fatal "'$STEP' now runs under a configured shell; update the interpreter this harness uses"
fi

env_val() { yq -r "$step_q | .env.$1 // \"\"" "$WORKFLOW"; }

CASE=contract
check
if grep -qF '${{' "$work/body.raw"; then
  fail "run body interpolates \${{ }} expressions; read inputs through env: instead"
fi
check
[ "$(env_val HEAD_REF)" = '${{ github.ref_name }}' ] ||
  fail "env.HEAD_REF is not \${{ github.ref_name }} (got '$(env_val HEAD_REF)')"
check
[ "$(env_val MERGE_METHOD)" = '${{ inputs.merge-method }}' ] ||
  fail "env.MERGE_METHOD is not \${{ inputs.merge-method }} (got '$(env_val MERGE_METHOD)')"
MAX_ATTEMPTS="$(env_val MAX_ATTEMPTS)"
SLEEP_BASE="$(env_val SLEEP_BASE)"
check
case "$MAX_ATTEMPTS" in '' | *[!0-9]* | 0 | 1)
  fail "env.MAX_ATTEMPTS must be an integer >= 2 (got '$MAX_ATTEMPTS')"; MAX_ATTEMPTS=6 ;; esac
check
case "$SLEEP_BASE" in '' | *[!0-9]* | 0)
  fail "env.SLEEP_BASE must be a positive integer (got '$SLEEP_BASE')"; SLEEP_BASE=5 ;; esac

# The runner substitutes expressions before bash sees the body. Do the same
# for the two contexts this step has used, so a body that still interpolates
# (the pre-retry form) can be executed and judged on behaviour too.
sed -e 's/\${{ *inputs\.merge-method *}}/${MERGE_METHOD}/g' \
    -e 's/\${{ *github\.ref_name *}}/${HEAD_REF}/g' "$work/body.raw" > "$work/body.sh"
if grep -qF '${{' "$work/body.sh"; then
  fatal "unrenderable expression left in the run body"
fi

# ---------------------------------------------------------------- stubs
mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Stub gh. Outcomes come from $STUB_DIR/<verb>.seq, one per call; the last line
# repeats once the sequence is exhausted.
echo "STUB-GH-7f3a9c $*" >> "$STUB_DIR/calls.log"
next() {
  local seq="$STUB_DIR/$1.seq" cnt="$STUB_DIR/$1.count" n total
  n=$(( $(cat "$cnt" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$cnt"
  total=$(wc -l < "$seq"); [ "$n" -le "$total" ] || n=$total
  sed -n "${n}p" "$seq"
}
case "$1 $2" in
  "pr view")
    # view.seq lines are STATE/MERGEABLE (or `error`). The stub builds the PR
    # JSON, keeps only the --json fields, and applies the body's own --jq
    # expression with jq, so the shipped expression is exercised too.
    fields="" expr=""
    shift 2
    while [ $# -gt 0 ]; do
      case "$1" in
        --json) fields=$2; shift 2 ;;
        --jq) expr=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    [ -n "$fields" ] || { echo "stub gh: view without --json" >&2; exit 98; }
    r=$(next view)
    if [ "$r" = "error" ]; then echo "HTTP 502: Bad Gateway (stub)" >&2; exit 1; fi
    json=$(jq -cn --arg s "${r%%/*}" --arg m "${r#*/}" --arg f "$fields" \
      '{state: $s, mergeable: $m, mergeStateStatus: $m}
       | with_entries(select(.key as $k | $f | split(",") | index($k)))')
    if [ -n "$expr" ]; then jq -r "$expr" <<< "$json"; else echo "$json"; fi ;;
  "pr merge")
    r=$(next merge)
    case "$r" in
      ok) echo "stub: merged or auto-merge enabled" ;;
      fail:*) echo "${r#fail:}" >&2; exit 1 ;;
    esac ;;
  *) echo "stub gh: unexpected call: $*" >&2; exit 97 ;;
esac
STUB
cat > "$work/bin/sleep" <<'STUB'
#!/usr/bin/env bash
echo "STUB-SLEEP $1" >> "$STUB_DIR/calls.log"
STUB
chmod +x "$work/bin/gh" "$work/bin/sleep"
[ "$(PATH="$work/bin:$PATH" command -v gh)" = "$work/bin/gh" ] || fatal "stub gh is not first on PATH"
[ "$(PATH="$work/bin:$PATH" command -v sleep)" = "$work/bin/sleep" ] || fatal "stub sleep is not first on PATH"

RACE='GraphQL: Base branch was modified. Review and try the merge again. (mergePullRequest)'
HEAD=image-updater-org/app/svc-1.2.3

# run_case NAME METHOD VIEW_SEQ MERGE_SEQ   (sequences are |-separated)
run_case() {
  CASE=$1
  local dir="$work/case-$1"
  mkdir -p "$dir/cwd"
  tr '|' '\n' <<< "$3" > "$dir/view.seq"
  tr '|' '\n' <<< "$4" > "$dir/merge.seq"
  : > "$dir/calls.log"
  set +e
  (cd "$dir/cwd" && env -i PATH="$work/bin:$PATH" HOME="$dir" STUB_DIR="$dir" \
    GH_TOKEN=stub GH_REPO=org/app HEAD_REF="$HEAD" MERGE_METHOD="$2" \
    MAX_ATTEMPTS="$MAX_ATTEMPTS" SLEEP_BASE="$SLEEP_BASE" \
    bash -e "$work/body.sh") > "$dir/out" 2>&1
  RC=$?
  set -e
  LOG="$dir/calls.log"
  OUT="$dir/out"
  check
  grep -q "^$SENTINEL " "$LOG" || fail "stub gh sentinel never logged; the real gh may have run"
}
count() { grep -c "^$1" "$LOG" || true; }
sleeps() { { grep '^STUB-SLEEP ' "$LOG" || true; } | awk '{print $2}' | paste -sd' ' -; }
expect_rc() { check; [ "$RC" = "$1" ] || fail "rc $RC, expected $1 (output: $(tr '\n' ' ' < "$OUT"))"; }
expect_count() { check; local n; n=$(count "$1"); [ "$n" = "$2" ] || fail "$3: $n call(s), expected $2"; }
expect_sleeps() { check; [ "$(sleeps)" = "$1" ] || fail "sleeps '$(sleeps)', expected '$1'"; }
expect_out() { check; grep -qF -- "$1" "$OUT" || fail "output lacks '$1'"; }
expect_out_n() { check; local n; n=$(grep -cF -- "$1" "$OUT" || true); [ "$n" = "$2" ] || fail "'$1' appears $n time(s), expected $2"; }

VIEW="$SENTINEL pr view"
MERGE="$SENTINEL pr merge"
B=$SLEEP_BASE
geometric() { local d=$B i out=""; for ((i = 0; i < $1; i++)); do out+="$d "; d=$((d * 2)); done; echo "${out% }"; }

# 1. Mergeability still computing: wait for it, then merge once.
run_case unknown-then-mergeable squash 'OPEN/UNKNOWN|OPEN/UNKNOWN|OPEN/MERGEABLE' 'ok'
expect_rc 0
expect_count "$VIEW" 3 "gh pr view"
expect_count "$MERGE" 1 "gh pr merge"
expect_sleeps "$B $B"
check
grep -qxF "$MERGE --auto --delete-branch --squash $HEAD" "$LOG" ||
  fail "merge args were not '--auto --delete-branch --squash $HEAD': $(grep "^$MERGE" "$LOG")"

# 2. The base-moved race: a sibling PR moves main twice, the third attempt lands.
run_case base-modified-twice squash 'OPEN/MERGEABLE' "fail:$RACE|fail:$RACE|ok"
expect_rc 0
expect_count "$MERGE" 3 "gh pr merge"
expect_out_n '::warning::' 2
expect_sleeps "$(geometric 2)"

# 3. Never succeeds: bounded, fails loudly, keeps gh's message.
run_case always-fails squash 'OPEN/MERGEABLE' "fail:$RACE"
expect_rc 1
expect_count "$MERGE" "$MAX_ATTEMPTS" "gh pr merge"
expect_out_n '::error::' 1
expect_out "::error::gh pr merge failed after $MAX_ATTEMPTS attempts: $RACE"
expect_sleeps "$(geometric $((MAX_ATTEMPTS - 1)))"

# 4. Happy path: one merge, no waiting.
run_case first-try rebase 'OPEN/MERGEABLE' 'ok'
expect_rc 0
expect_count "$MERGE" 1 "gh pr merge"
expect_sleeps ""
check
grep -q -- "^$MERGE .*--rebase $HEAD\$" "$LOG" || fail "merge-method rebase did not reach gh as --rebase"

# 5. Mergeability never settles: the wait is bounded and the merge still runs.
run_case unknown-forever squash 'OPEN/UNKNOWN' 'ok'
expect_rc 0
expect_count "$VIEW" "$MAX_ATTEMPTS" "gh pr view"
expect_count "$MERGE" 1 "gh pr merge"

# 6. A failed mergeability read does not abort the step.
run_case view-errors squash 'error' 'ok'
expect_rc 0
expect_count "$MERGE" 1 "gh pr merge"

# 7. The merge landed but gh exited non-zero (remote branch delete failed). A
#    merged PR reads mergeable UNKNOWN indefinitely, so the retry must stop on
#    state MERGED instead of spending the UNKNOWN wait and merging again.
DELETE_ERR="failed to delete remote branch $HEAD: HTTP 500: Internal Server Error (stub)"
run_case merged-after-failed-attempt squash 'OPEN/MERGEABLE|MERGED/UNKNOWN' "fail:$DELETE_ERR|ok"
expect_rc 0
expect_count "$VIEW" 2 "gh pr view"
expect_count "$MERGE" 1 "gh pr merge"
expect_sleeps "$B"
expect_out "::warning::gh pr merge attempt 1/$MAX_ATTEMPTS failed, retrying in ${B}s: $DELETE_ERR"
expect_out "already merged"

# ---------------------------------------------------------------- class scan
# Every step that merges a PR, or enables auto-merge, is exposed to the same
# base-moved race.
CASE=scan
found=0
for f in .github/workflows/*.yml .github/workflows/*.yaml workflow-templates/*.yml workflow-templates/*.yaml; do
  [ -f "$f" ] || continue
  # `\x5c` is a backslash, so `gh pr \<newline> merge` matches too. Steps that
  # merge through an action (`uses:`) are flagged by name.
  steps="$(yq -r '.jobs[]?.steps[]? | select(((.run // "") | test("gh[\\s\\x5c]+pr[\\s\\x5c]+merge|/pulls/[^ ]*/merge|mergePullRequest|enablePullRequestAutoMerge")) or ((.uses // "") | test("(?i)auto-?merge|merge-pull-request"))) | (.name // "<unnamed step>")' "$f")" ||
    fatal "yq could not parse $f"
  while IFS= read -r step; do
    [ -n "$step" ] || continue
    check
    allowed=0
    for a in "${ALLOWED[@]}"; do [ "$a" = "$f|$step" ] && allowed=1; done
    if [ "$allowed" = 1 ]; then
      found=$((found + 1))
    else
      fail "$f step '$step' merges a PR outside a tested retry; wrap it like '$STEP' in $WORKFLOW and add it to ALLOWED with scenarios"
    fi
  done <<< "$steps"
done
# Control: the scan must see the step it knows about, or it scanned nothing.
[ "$found" -ge 1 ] || fatal "class scan did not find '$STEP' in $WORKFLOW; the scan is broken"

if [ "$failures" -gt 0 ]; then
  echo "FAIL: $NAME ($failures of $checks assertion(s) failed)"
  exit 1
fi
echo "PASS: $NAME ($checks assertion(s))"

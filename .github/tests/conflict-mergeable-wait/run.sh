#!/usr/bin/env bash
# The single-quoted ${{ }} strings below are literal workflow expressions.
# shellcheck disable=SC2016
#
# The two conflict reusables read each PR's `mergeable` field on push to main,
# which is exactly when GitHub recomputes it and reports UNKNOWN. An UNKNOWN
# read used to be treated as clean, so a conflicting PR was skipped with no
# message. Both steps must now re-read (bounded by MAX_POLLS, POLL_SLEEP
# seconds apart) while a candidate is UNKNOWN, warn naming the PRs still
# UNKNOWN when the bound runs out, and fail when gh fails instead of reporting
# "no conflicts".
#
# It EXTRACTS each shipped `run:` body with yq and executes that under the
# shell GitHub uses for a step with no `shell:` (`bash -e {0}`), with stub `gh`
# and `sleep` first on PATH. It never holds a retyped copy of either step.
#
# It also scans every workflow for other `run:` steps that read the field
# (`.mergeable`, `,mergeable` in a --json list); each one is exposed to the same
# UNKNOWN window, so each must be listed in ALLOWED and covered by a harness.
#
# AR_WORKFLOW / FR_WORKFLOW override the files under test (e.g. a
# `git show origin/main:` copy, to prove the scenarios fail on the pre-fix tree).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

NAME=conflict-mergeable-wait
AR_WF_DEFAULT=.github/workflows/reusable-auto-resolve-conflicts.yml
FR_WF_DEFAULT=.github/workflows/reusable-fix-release-conflicts.yml
AR_WORKFLOW=${AR_WORKFLOW:-$AR_WF_DEFAULT}
FR_WORKFLOW=${FR_WORKFLOW:-$FR_WF_DEFAULT}
AR_STEP="Find conflicting PRs"
FR_STEP="Check for conflicted release-please PR"
# auto-merge-retry covers "Enable auto-merge" (its own UNKNOWN wait).
ALLOWED=(
  "$AR_WF_DEFAULT|$AR_STEP"
  "$FR_WF_DEFAULT|$FR_STEP"
  ".github/workflows/reusable-auto-merge-image-updater.yml|Enable auto-merge"
)
SENTINEL=STUB-GH-c41e8b
RP_BRANCH=release-please--branches--main

fatal() { echo "FATAL: $*" >&2; exit 1; }
command -v yq >/dev/null || fatal "yq is required (mikefarah/yq v4)"
command -v jq >/dev/null || fatal "jq is required (the stub gh applies --jq with it)"
command -v timeout >/dev/null || fatal "timeout is required (an unbounded wait must not hang the suite)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0
checks=0
CASE=setup
fail() { printf '  FAIL [%s] %s\n' "$CASE" "$1"; failures=$((failures + 1)); }
check() { checks=$((checks + 1)); }

# ---------------------------------------------------------------- extraction
# extract TAG WORKFLOW STEP: writes $work/TAG.raw and prints nothing.
extract() {
  local tag=$1 wf=$2 step=$3 q
  q=".jobs[].steps[] | select(.name == \"$step\")"
  [ -f "$wf" ] || fatal "$wf not found"
  [ "$(yq "[$q] | length" "$wf")" = 1 ] || fatal "expected exactly one '$step' step in $wf"
  yq -r "$q | .run" "$wf" > "$work/$tag.raw"
  [ -s "$work/$tag.raw" ] || fatal "no '$step' run body extracted from $wf"
  # Executed with `bash -e`: what the runner uses for a step without `shell:`
  # and without a job/workflow `defaults.run.shell`.
  if [ "$(yq "$q | .shell // \"\"" "$wf")" != "" ] ||
     [ "$(yq '[.. | select(tag == "!!map" and has("defaults"))] | length' "$wf")" != 0 ]; then
    fatal "'$step' in $wf now runs under a configured shell; update the interpreter this harness uses"
  fi

  CASE="$tag-contract"
  check
  if grep -qF '${{' "$work/$tag.raw"; then
    fail "run body interpolates \${{ }} expressions; read them through env: instead"
  fi
  check
  [ "$(yq -r "$q | .env.REPO // \"\"" "$wf")" = '${{ github.repository }}' ] ||
    fail "env.REPO is not \${{ github.repository }}"
  local v k
  for k in MAX_POLLS POLL_SLEEP; do
    v=$(yq -r "$q | .env.$k // \"\"" "$wf")
    check
    case "$v" in '' | *[!0-9]* | 0*) fail "env.$k must be a positive integer (got '$v')" ;; esac
  done

  # A body that still interpolates (the pre-fix form) must only use the
  # contexts render() knows, so it can be executed and judged on behaviour too.
  sed -e 's/\${{ *inputs\.pr_number *}}//g' -e 's/\${{ *github\.repository *}}//g' "$work/$tag.raw" |
    grep -F '${{' >/dev/null && fatal "unrenderable expression left in the '$step' run body"
  return 0
}

# render TAG PR_NUMBER: the runner pastes expression values into the script
# before bash sees it. Do the same, with the case's value.
render() {
  local v
  v=$(printf '%s' "$2" | sed -e 's/[\/&]/\\&/g')
  sed -e "s/\${{ *inputs\.pr_number *}}/$v/g" \
      -e 's/\${{ *github\.repository *}}/org\/app/g' "$work/$1.raw" > "$work/$1.sh"
}
extract ar "$AR_WORKFLOW" "$AR_STEP"
extract fr "$FR_WORKFLOW" "$FR_STEP"
CASE=ar-contract
check
[ "$(yq -r ".jobs[].steps[] | select(.name == \"$AR_STEP\") | .env.PR_INPUT // \"\"" "$AR_WORKFLOW")" = '${{ inputs.pr_number }}' ] ||
  fail "[ar] env.PR_INPUT is not \${{ inputs.pr_number }}"

# The behaviour scenarios use the shipped bound when it is valid, and the
# pre-fix implicit values otherwise (so a pre-fix tree still runs).
shipped() { # TAG KEY FALLBACK
  local wf step v
  if [ "$1" = ar ]; then wf=$AR_WORKFLOW step=$AR_STEP; else wf=$FR_WORKFLOW step=$FR_STEP; fi
  v=$(yq -r ".jobs[].steps[] | select(.name == \"$step\") | .env.$2 // \"\"" "$wf")
  case "$v" in '' | *[!0-9]* | 0*) echo "$3" ;; *) echo "$v" ;; esac
}

# ---------------------------------------------------------------- stubs
mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Stub gh. `gh pr list` serves the next line of $STUB_DIR/list.seq per call
# (the last line repeats): `error`, or space-separated NUMBER=MERGEABLE@BRANCH
# tokens (`-` for no open PR). The stub applies --head, --limit, the --json
# field list and -q/--jq through real jq, so the body's own expressions are
# exercised. `gh pr view N` returns PR N on a feature branch; `gh api` answers
# the default-branch (main) and branch-protection (unprotected) lookups;
# `gh pr comment` / `gh pr close` are logged.
echo "STUB-GH-c41e8b $*" >> "$STUB_DIR/calls.log"
sub="$1 $2"
shift 2
fields="" expr="" head="" limit=30 pos=()
while [ $# -gt 0 ]; do
  case "$1" in
    --json) fields=$2; shift 2 ;;
    -q | --jq) expr=$2; shift 2 ;;
    --head) head=$2; shift 2 ;;
    --limit | -L) limit=$2; shift 2 ;;
    --repo | -R | --state | --body) shift 2 ;;
    --delete-branch) shift ;;
    -*) echo "stub gh: unknown flag $1" >&2; exit 96 ;;
    *) pos+=("$1"); shift ;;
  esac
done
out() { if [ -n "$expr" ]; then jq -rc "$expr" <<< "$1"; else echo "$1"; fi; }
case "$sub" in
  "pr list") ;;
  "pr view")
    out "$(jq -cn --argjson n "${pos[0]}" '{number: $n, headRefName: "feat/dispatch", isCrossRepository: false}')"
    exit 0 ;;
  "pr comment") exit 0 ;;
  "pr close") echo "${pos[0]}" >> "$STUB_DIR/closed.log"; exit 0 ;;
  api\ *)
    path=${sub#api }
    case "$path" in
      repos/org/app) out '{"default_branch": "main"}' ;;
      repos/org/app/branches/*) out '{"protected": false}' ;;
      *) echo "stub gh: unexpected api path $path" >&2; exit 97 ;;
    esac
    exit 0 ;;
  *) echo "stub gh: unexpected call: $sub" >&2; exit 97 ;;
esac
[ -n "$fields" ] || { echo "stub gh: pr list without --json" >&2; exit 98; }
cnt="$STUB_DIR/list.count"
n=$(( $(cat "$cnt" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$cnt"
total=$(wc -l < "$STUB_DIR/list.seq"); [ "$n" -le "$total" ] || n=$total
line=$(sed -n "${n}p" "$STUB_DIR/list.seq")
if [ "$line" = error ]; then echo "HTTP 502: Bad Gateway (stub)" >&2; exit 1; fi
json=$(jq -cn --arg line "$line" --arg head "$head" --arg f "$fields" --argjson limit "$limit" '
  [$line | split(" ")[] | select(. != "" and . != "-")
   | capture("^(?<n>[0-9]+)=(?<m>[A-Z]+)@(?<b>.+)$")
   | {number: (.n | tonumber), mergeable: .m, headRefName: .b, isCrossRepository: false}]
  | map(select($head == "" or .headRefName == $head)) | .[:$limit]
  | map(with_entries(select(.key as $k | $f | split(",") | index($k))))')
out "$json"
STUB
cat > "$work/bin/sleep" <<'STUB'
#!/usr/bin/env bash
echo "STUB-SLEEP $1" >> "$STUB_DIR/calls.log"
STUB
chmod +x "$work/bin/gh" "$work/bin/sleep"
[ "$(PATH="$work/bin:$PATH" command -v gh)" = "$work/bin/gh" ] || fatal "stub gh is not first on PATH"
[ "$(PATH="$work/bin:$PATH" command -v sleep)" = "$work/bin/sleep" ] || fatal "stub sleep is not first on PATH"

# run_case TAG NAME SEQ [VAR=VALUE ...]   (SEQ is |-separated)
run_case() {
  local tag=$1
  CASE="$tag-$2"
  local dir="$work/case-$CASE"
  mkdir -p "$dir/cwd"
  tr '|' '\n' <<< "$3" > "$dir/list.seq"
  : > "$dir/calls.log"
  : > "$dir/output"
  : > "$dir/closed.log"
  shift 3
  local a pr="" max sl
  for a in "$@"; do case "$a" in PR_INPUT=*) pr=${a#PR_INPUT=} ;; esac; done
  render "$tag" "$pr"
  max=$(shipped "$tag" MAX_POLLS 6)
  sl=$(shipped "$tag" POLL_SLEEP 10)
  set +e
  (cd "$dir/cwd" && env -i PATH="$work/bin:$PATH" HOME="$dir" STUB_DIR="$dir" \
    GITHUB_OUTPUT="$dir/output" GH_TOKEN=stub REPO=org/app \
    PR_INPUT="" SKIP_RELEASE_PLEASE=false MAX_POLLS="$max" POLL_SLEEP="$sl" \
    "$@" timeout 20 bash -e "$work/$tag.sh") > "$dir/out" 2>&1
  RC=$?
  set -e
  LOG="$dir/calls.log"
  OUT="$dir/out"
  GOUT="$dir/output"
  CLOSED="$dir/closed.log"
}
calls() { grep -c "^$SENTINEL pr list" "$LOG" || true; }
sleeps() { { grep '^STUB-SLEEP ' "$LOG" || true; } | awk '{print $2}' | paste -sd' ' -; }
outv() { { grep "^$1=" "$GOUT" || true; } | tail -n 1 | cut -d= -f2-; }
matrix_prs() { jq -r '[.include[].pr_number] | join(" ")' <<< "$(outv matrix)" 2>/dev/null || echo "<invalid matrix>"; }
ctx() { echo "(rc $RC; output: $(tr '\n' ' ' < "$OUT"))"; }
expect_rc() { check; [ "$RC" = "$1" ] || fail "rc $RC, expected $1 $(ctx)"; }
expect_rc_nonzero() { check; [ "$RC" != 0 ] || fail "step exited 0, expected a failure $(ctx)"; }
expect_calls() { check; [ "$(calls)" = "$1" ] || fail "gh pr list called $(calls) time(s), expected $1 $(ctx)"; }
expect_sentinel() {
  check
  grep -q "^$SENTINEL " "$LOG" || fail "stub gh sentinel never logged; the real gh may have run"
  check
  grep -q "^$SENTINEL pr list .*--repo org/app" "$LOG" || fail "gh pr list did not pass --repo org/app"
}
expect_sleeps() { check; [ "$(sleeps)" = "$1" ] || fail "sleeps '$(sleeps)', expected '$1'"; }
expect_out() { check; grep -qF -- "$1" "$OUT" || fail "output lacks '$1' $(ctx)"; }
expect_no_out() { check; grep -qF -- "$1" "$OUT" && fail "output contains '$1' $(ctx)"; return 0; }
expect_outv() { check; [ "$(outv "$1")" = "$2" ] || fail "GITHUB_OUTPUT $1='$(outv "$1")', expected '$2' $(ctx)"; }
expect_matrix() { check; [ "$(matrix_prs)" = "$1" ] || fail "matrix PRs '$(matrix_prs)', expected '$1' $(ctx)"; }
expect_closed() { check; [ "$(paste -sd' ' - < "$CLOSED")" = "$1" ] || fail "closed PRs '$(paste -sd' ' - < "$CLOSED")', expected '$1' $(ctx)"; }
repeat() { local i out=""; for ((i = 0; i < $1; i++)); do out+="$2 "; done; echo "${out% }"; }

# ================================================= reusable-auto-resolve-conflicts
ARM=$(shipped ar MAX_POLLS 6)
ARS=$(shipped ar POLL_SLEEP 10)

# (a) The incident case: read UNKNOWN right after the push, then CONFLICTING.
run_case ar unknown-then-conflicting '12=UNKNOWN@feat/a|12=CONFLICTING@feat/a'
expect_rc 0
expect_sentinel
expect_calls 2
expect_sleeps "$ARS"
expect_matrix 12
expect_outv has_conflicts true
expect_out "Mergeability UNKNOWN for 1 PR(s) (#12); waiting ${ARS}s (1/$ARM)"

# (a') Several PRs: a clean one stays out, a conflicting one is not lost while
#      another settles.
run_case ar mixed '12=UNKNOWN@feat/a 13=MERGEABLE@feat/b 14=CONFLICTING@feat/c|12=CONFLICTING@feat/a 13=MERGEABLE@feat/b 14=CONFLICTING@feat/c'
expect_rc 0
expect_calls 2
expect_sleeps "$ARS"
expect_matrix '12 14'

# (b) Settled on the first read: no waiting, nothing selected.
run_case ar mergeable '12=MERGEABLE@feat/a'
expect_rc 0
expect_sentinel
expect_calls 1
expect_sleeps ""
expect_matrix ""
expect_outv has_conflicts false
expect_out "::notice::No PRs with merge conflicts to resolve"

# (c) Never settles: bounded, warns with the count and the PR, excludes it,
#     and still selects the PR that did read CONFLICTING.
run_case ar unknown-forever '12=UNKNOWN@feat/a 14=CONFLICTING@feat/c'
expect_rc 0
expect_calls $((ARM + 1))
expect_sleeps "$(repeat "$ARM" "$ARS")"
expect_out "::warning::1 PR(s) still read mergeable UNKNOWN after $ARM polls and were not resolved: #12"
expect_matrix 14
expect_outv has_conflicts true

# (c') The bound comes from env, not a constant in the body.
run_case ar unknown-forever-bound2 '12=UNKNOWN@feat/a 15=UNKNOWN@feat/d' MAX_POLLS=2 POLL_SLEEP=3
expect_rc 0
expect_calls 3
expect_sleeps "3 3"
expect_out "::warning::2 PR(s) still read mergeable UNKNOWN after 2 polls and were not resolved: #12 #15"
expect_matrix ""
expect_outv has_conflicts false

# (c'') An invalid bound fails fast instead of looping or skipping the wait.
run_case ar bad-bound '12=UNKNOWN@feat/a' MAX_POLLS=abc
expect_rc_nonzero
expect_sleeps ""
expect_out "::error::"

# (d) gh fails: the step fails, it does not report "no conflicts".
run_case ar gh-error 'error'
expect_rc_nonzero
expect_no_out "No PRs with merge conflicts to resolve"
expect_outv has_conflicts ""
run_case ar gh-error-mid-wait '12=UNKNOWN@feat/a|error'
expect_rc_nonzero
expect_calls 2
expect_outv has_conflicts ""

# (e) skip-release-please: an UNKNOWN release-please PR is not waited for and
#     never selected or closed, even once it reads CONFLICTING.
run_case ar skip-release-please "7=UNKNOWN@$RP_BRANCH 12=MERGEABLE@feat/a|7=CONFLICTING@$RP_BRANCH 12=MERGEABLE@feat/a" SKIP_RELEASE_PLEASE=true
expect_rc 0
expect_calls 1
expect_sleeps ""
expect_matrix ""
expect_closed ""
expect_no_out "::warning::"
# Control: without the skip the same PR is waited for and, once it reads
# CONFLICTING, closed as a stale automated PR (never sent to resolve).
run_case ar no-skip-release-please "7=UNKNOWN@$RP_BRANCH 12=MERGEABLE@feat/a|7=CONFLICTING@$RP_BRANCH 12=MERGEABLE@feat/a"
expect_rc 0
expect_calls 2
expect_closed 7
expect_matrix ""

# (f) workflow_dispatch with pr_number: gh pr list is never called.
run_case ar dispatch '12=UNKNOWN@feat/a' PR_INPUT=42
expect_rc 0
expect_calls 0
expect_sleeps ""
expect_matrix 42
expect_outv has_conflicts true
# A non-numeric pr_number is refused: the matrix value reaches the resolve
# job's steps, so it must never reach the matrix.
run_case ar dispatch-not-a-number '12=UNKNOWN@feat/a' 'PR_INPUT=1$(touch pwned)'
expect_rc_nonzero
expect_calls 0
expect_outv matrix ""
check
[ ! -e "$work/case-$CASE/cwd/pwned" ] || fail "pr_number was executed as shell"

# ================================================= reusable-fix-release-conflicts
FRM=$(shipped fr MAX_POLLS 6)
FRS=$(shipped fr POLL_SLEEP 10)

# (a) UNKNOWN then CONFLICTING: the release-please PR is closed and recreated.
run_case fr unknown-then-conflicting "7=UNKNOWN@$RP_BRANCH|7=CONFLICTING@$RP_BRANCH"
expect_rc 0
expect_sentinel
expect_calls 2
expect_sleeps "$FRS"
expect_outv has_conflict true
expect_outv pr_number 7
expect_outv branch "$RP_BRANCH"
check
[ "$(grep -c '^has_conflict=' "$GOUT")" = 1 ] || fail "has_conflict written more than once: $(tr '\n' ' ' < "$GOUT")"
expect_out "Mergeability UNKNOWN for release-please PR #7; waiting ${FRS}s (1/$FRM)"

# (b) MERGEABLE on the first read: no waiting, no conflict.
run_case fr mergeable "7=MERGEABLE@$RP_BRANCH"
expect_rc 0
expect_sentinel
expect_calls 1
expect_sleeps ""
expect_outv has_conflict false
expect_outv pr_number ""

# (c) Never settles: bounded, warns naming the PR and the bound, no conflict.
run_case fr unknown-forever "7=UNKNOWN@$RP_BRANCH"
expect_rc 0
expect_calls $((FRM + 1))
expect_sleeps "$(repeat "$FRM" "$FRS")"
expect_out "::warning::release-please PR #7 still reads mergeable UNKNOWN after $FRM polls; the scheduled run will retry"
expect_outv has_conflict false
expect_outv pr_number ""
run_case fr unknown-forever-bound2 "7=UNKNOWN@$RP_BRANCH" MAX_POLLS=2 POLL_SLEEP=3
expect_rc 0
expect_calls 3
expect_sleeps "3 3"
run_case fr bad-bound "7=UNKNOWN@$RP_BRANCH" POLL_SLEEP=-1
expect_rc_nonzero
expect_sleeps ""
expect_out "::error::"

# (d) gh fails: the step fails instead of reading as "no PR".
run_case fr gh-error 'error'
expect_rc_nonzero
expect_no_out "No open release-please PR found"
expect_outv has_conflict ""
run_case fr gh-error-mid-wait "7=UNKNOWN@$RP_BRANCH|error"
expect_rc_nonzero
expect_calls 2
expect_outv has_conflict ""

# No release-please PR open (another PR is): one read, no conflict.
run_case fr no-pr '12=CONFLICTING@feat/a'
expect_rc 0
expect_calls 1
expect_out "No open release-please PR found"
expect_outv has_conflict false
# The release-please PR closed while waiting: stop, no conflict.
run_case fr closed-mid-wait "7=UNKNOWN@$RP_BRANCH|-"
expect_rc 0
expect_calls 2
expect_outv has_conflict false

# ---------------------------------------------------------------- class scan
# Every run: step that reads the `mergeable` field lands in the same UNKNOWN
# window. The pattern matches a field read (`.mergeable`, `,mergeable` or
# `--json mergeable`), not the word in a comment body.
CASE=scan
READS='(\.|,|--json\s+)mergeable\b'
# Control: the pattern matches a field read and not prose.
check
[ "$(R="$READS" yq -n '"--json number,mergeable,headRefName" | test(strenv(R))')" = true ] || fail "scan pattern misses a --json field list"
check
[ "$(R="$READS" yq -n '"did not produce a mergeable result" | test(strenv(R))')" = false ] || fail "scan pattern matches prose"
found=0
for f in .github/workflows/*.yml .github/workflows/*.yaml; do
  [ -f "$f" ] || continue
  steps="$(R="$READS" yq -r '.jobs[]?.steps[]? | select((.run // "") | test(strenv(R))) | (.name // "<unnamed step>")' "$f")" ||
    fatal "yq could not parse $f"
  while IFS= read -r step; do
    [ -n "$step" ] || continue
    check
    allowed=0
    for a in "${ALLOWED[@]}"; do [ "$a" = "$f|$step" ] && allowed=1; done
    if [ "$allowed" = 1 ]; then
      found=$((found + 1))
    else
      fail "$f step '$step' reads mergeable outside a tested UNKNOWN wait; wrap it like '$AR_STEP' and add it to ALLOWED with scenarios"
    fi
  done <<< "$steps"
done
# Control: the scan must see the steps it knows about, or it scanned nothing.
[ "$found" -ge "${#ALLOWED[@]}" ] || fatal "class scan found $found of the ${#ALLOWED[@]} known steps; the scan is broken"

if [ "$failures" -gt 0 ]; then
  echo "FAIL: $NAME ($failures of $checks assertion(s) failed)"
  exit 1
fi
echo "PASS: $NAME ($checks assertion(s))"

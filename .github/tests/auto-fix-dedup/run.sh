#!/usr/bin/env bash
# Fixture harness for the issue deduplication in reusable-auto-fix.yml.
#
# Without it the workflow filed one new issue per failing run: eight in
# laurigates/dotfiles (#414-#429) for a single unresolvable `uses:` ref, from
# eight runs on seven branches. This harness checks the three steps that
# prevent that, plus the prompt wiring that makes the agent honour them.
#
# It EXTRACTS the shipped `run:` bodies with yq and executes those. It never
# holds a retyped copy (same rule as .github/tests/publish-findings/run.sh).
#
# The logs in fixtures/ are real `gh run view <id> --log-failed` output. The
# Homebrew and context-budget logs are whole; the StyLua and mcu-tinkering-lab
# logs are cut to their header plus the failing region onwards. cases.tsv maps
# each log to the workflow name and branch of its run and to its failure group.
#
# Usage: bash .github/tests/auto-fix-dedup/run.sh [workflow-file]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

WORKFLOW="${1:-.github/workflows/reusable-auto-fix.yml}"
FIXTURES=.github/tests/auto-fix-dedup/fixtures

for tool in yq jq sha256sum; do
  command -v "$tool" >/dev/null || { echo "FATAL: $tool not found on PATH" >&2; exit 1; }
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

SIG_STEP='Compute failure signature'
LOOKUP_STEP='Find existing issue for this failure'
LABEL_STEP='Ensure issue labels exist'
CLAUDE_STEP='Analyze and fix with Claude'

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
# A field of the named step, as the exact string GitHub receives.
step_field() { # <step name> <yq path relative to the step>
  STEP="$1" yq -r ".jobs[\"auto-fix\"].steps[] | select(.name == strenv(STEP)) | ($2) // \"\"" "$WORKFLOW"
}
step_env_keys() { # <step name> -> space-separated env keys
  STEP="$1" yq -r '.jobs["auto-fix"].steps[] | select(.name == strenv(STEP)) | (.env // {}) | keys | join(" ")' "$WORKFLOW"
}
# The harness sets these variables; the step must bind every one via env:.
assert_env_binds() { # <step name> <var...>
  local step="$1" keys
  shift
  keys=" $(step_env_keys "$step") "
  for var in "$@"; do
    ok
    case "$keys" in *" $var "*) ;; *) fail "'$step' does not bind $var in env:" ;; esac
  done
}

echo "== auto-fix-dedup against $WORKFLOW"

# ----------------------------------------------------------------- structure
CASE_NAME=structure
have_sig=0; have_lookup=0; have_label=0
step_field "$SIG_STEP" .run > "$work/signature.sh"
step_field "$LOOKUP_STEP" .run > "$work/lookup.sh"
step_field "$LABEL_STEP" .run > "$work/labels.sh"
ok; if [ -s "$work/signature.sh" ]; then have_sig=1; else
  fail "no '$SIG_STEP' step: nothing fingerprints a failure, so no run can recognise one already filed"; fi
ok; if [ -s "$work/lookup.sh" ]; then have_lookup=1; else
  fail "no '$LOOKUP_STEP' step: nothing looks for an open issue before the agent files one"; fi
ok; if [ -s "$work/labels.sh" ]; then have_label=1; else
  fail "no '$LABEL_STEP' step: 'gh issue create --label ci-failure' fails in repos without that label"; fi

# Step order: each step consumes the previous one's outputs.
names="$(yq -r '.jobs["auto-fix"].steps[].name' "$WORKFLOW")"
pos() { printf '%s\n' "$names" | { grep -nxF -- "$1" || true; } | cut -d: -f1; }
p_ctx="$(pos 'Gather failure context')"; p_sig="$(pos "$SIG_STEP")"; p_lookup="$(pos "$LOOKUP_STEP")"
p_label="$(pos "$LABEL_STEP")"; p_claude="$(pos "$CLAUDE_STEP")"
ok
if [ -n "$p_ctx" ] && [ -n "$p_sig" ] && [ -n "$p_lookup" ] && [ -n "$p_label" ] && [ -n "$p_claude" ] \
   && [ "$p_ctx" -lt "$p_sig" ] && [ "$p_sig" -lt "$p_lookup" ] && [ "$p_lookup" -lt "$p_label" ] \
   && [ "$p_label" -lt "$p_claude" ]; then :; else
  fail "steps must run in order: context < signature < lookup < labels < Claude (got ${p_ctx:-?} ${p_sig:-?} ${p_lookup:-?} ${p_label:-?} ${p_claude:-?})"
fi

# The prompt must take its issue instructions from the lookup, not hard-code
# an unconditional `gh issue create`.
prompt="$(step_field "$CLAUDE_STEP" .with.prompt)"
# shellcheck disable=SC2016 # a literal GitHub expression, not a shell one
assert_contains "$prompt" '${{ steps.existing.outputs.directive }}' "Claude prompt"
assert_lacks "$prompt" 'gh issue create' "Claude prompt (issue creation belongs to the directive)"

# The old flood guard counted `head:auto-fix/` PRs, which this workflow never
# opens; `head:` is also an exact-match qualifier. It could never fire.
all_runs="$(yq -r '.jobs["auto-fix"].steps[].run // ""' "$WORKFLOW")"
assert_lacks "$all_runs" 'head:auto-fix/' "workflow run bodies"
assert_eq "$(step_field "$CLAUDE_STEP" .if)" "steps.context.outputs.recent_fix_count == '0'" "Claude step if:"
assert_contains "$(step_field "$LABEL_STEP" .if)" "steps.existing.outputs.mode == 'create'" "label step if:"

# The new steps read inputs from env:, never from ${{ }} inside the script.
for f in signature lookup labels; do
  # shellcheck disable=SC2016 # a literal GitHub expression, not a shell one
  assert_lacks "$(cat "$work/$f.sh")" '${{' "$f run body"
done

# ---------------------------------------------------------------- signatures
run_sig() { # <log file or ''> <workflow name> <branch>
  rm -rf "$work/run"
  mkdir -p "$work/run/ctx"
  if [ -n "$1" ]; then cp "$1" "$work/run/ctx/failure-logs.txt"; fi
  : > "$work/run/output"
  set +e
  GITHUB_OUTPUT="$work/run/output" CONTEXT_DIR="$work/run/ctx" WORKFLOW_NAME="$2" BRANCH="$3" \
    bash "$work/signature.sh" > "$work/run/stdout" 2> "$work/run/stderr"
  RC=$?
  set -e
  SIG="$(sed -n 's/^signature=//p' "$work/run/output")"
  SRC="$(sed -n 's/^source=//p' "$work/run/output")"
  LINE="$(sed -n 's/^Signature input: //p' "$work/run/stdout")"
}

expect_group() {
  case "$1" in
    homebrew)
      EXP_SRC=error
      # shellcheck disable=SC2016 # the backticks are part of the log line
      EXP_LINE='Unable to resolve action `homebrew/actions@master`, unable to find version `master`' ;;
    stylua)
      EXP_SRC=exception
      EXP_LINE='requests.exceptions.HTTPError: 403 Client Error: rate limit exceeded for url: https://api.github.com/repos/JohnnyMorganz/StyLua/releases' ;;
    context-budget)
      EXP_SRC=hook
      EXP_LINE='pre-commit hook failed: claude-context-budget' ;;
    mcu-ty)
      EXP_SRC=hook
      EXP_LINE='pre-commit hook failed: ty' ;;
    *) EXP_SRC='?'; EXP_LINE='?' ;;
  esac
}

if [ "$have_sig" = 1 ]; then
  CASE_NAME='signature-env'
  assert_env_binds "$SIG_STEP" CONTEXT_DIR WORKFLOW_NAME BRANCH

  : > "$work/sigs.tsv"
  while IFS=$'\t' read -r group workflow branch fixture; do
    [ "$group" = group ] && continue
    CASE_NAME="$group/${fixture%.log}"
    run_sig "$FIXTURES/$fixture" "$workflow" "$branch"
    expect_group "$group"
    assert_eq "$RC" 0 "exit code"
    ok; printf '%s' "$SIG" | grep -qE '^[0-9a-f]{12}$' || fail "signature '$SIG' is not 12 hex chars"
    assert_eq "$SRC" "$EXP_SRC" "source"
    assert_eq "$LINE" "$EXP_LINE" "signature input"
    printf '%s\t%s\n' "$group" "$SIG" >> "$work/sigs.tsv"
  done < "$FIXTURES/cases.tsv"

  # One signature per failure, one failure per signature.
  CASE_NAME=grouping
  groups="$(cut -f1 "$work/sigs.tsv" | sort -u)"
  for g in $groups; do
    n="$(awk -F'\t' -v g="$g" '$1 == g { print $2 }' "$work/sigs.tsv" | sort -u | wc -l | tr -d ' ')"
    assert_eq "$n" 1 "distinct signatures in group $g"
  done
  assert_eq "$(cut -f2 "$work/sigs.tsv" | sort -u | wc -l | tr -d ' ')" \
    "$(printf '%s\n' "$groups" | wc -l | tr -d ' ')" "distinct signatures across groups"

  # A branch name is replaced only as a whole token. A substring replace would
  # turn every 'a' into '<branch>' for a branch named 'a'.
  CASE_NAME='branch-token'
  run_sig "$FIXTURES/dotfiles-34770384899.log" 'Smoke Test CI' 'fix/enable-github-actions-migration-plugins'
  ref="$SIG"
  run_sig "$FIXTURES/dotfiles-34770384899.log" 'Smoke Test CI' 'a'
  assert_eq "$SIG" "$ref" "signature with branch 'a'"
  run_sig "$FIXTURES/dotfiles-34770384899.log" 'Smoke Test CI' 'e'
  assert_eq "$SIG" "$ref" "signature with branch 'e'"

  # The workflow name is part of the signature.
  CASE_NAME='workflow-scope'
  run_sig "$FIXTURES/dotfiles-34770384899.log" 'Other CI' 'x'
  ok; [ -n "$SIG" ] && [ "$SIG" != "$ref" ] || fail "same line in another workflow must not share the signature"

  # Synthetic: every volatile token class in one line. Two runs of the same
  # failure differ in run id, SHA, timestamp, UUID, runner temp path and
  # branch; a third differs in one meaningful word.
  CASE_NAME='volatile-tokens'
  synth() { # <run id> <sha> <timestamp> <uuid> <tmp dir> <branch> <artifact word>
    printf 'build\tUNKNOWN STEP\t2026-01-01T00:00:00.0000000Z ##[group]Run fetch\n'
    printf 'build\tUNKNOWN STEP\t2026-01-01T00:00:01.0000000Z ##[error]Failed to fetch %s for https://github.com/o/r/actions/runs/%s at %s (refs/heads/%s) into /home/runner/work/_temp/%s/out.zip via %s/pip-build-env-x at %s\n' \
      "$7" "$1" "$2" "$6" "$4" "$5" "$3"
    printf 'build\tUNKNOWN STEP\t2026-01-01T00:00:02.0000000Z ##[error]Process completed with exit code 1.\n'
  }
  synth 35728723228 a95de74c0ffee 2026-09-22T12:42:21.6272170Z 92636665-3d1e-4f9f-b655-bafc18f1b6d9 /tmp/tmp8h2k feat/one artifacts > "$work/s1.log"
  synth 34770384899 be2fd3b1234567 2026-09-13T17:02:42Z 0f1e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5b /tmp/tmpzz91 fix/two artifacts > "$work/s2.log"
  synth 34770384899 be2fd3b1234567 2026-09-13T17:02:42Z 0f1e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5b /tmp/tmpzz91 fix/two releases > "$work/s3.log"
  run_sig "$work/s1.log" 'CI' 'feat/one'; s1="$SIG"; l1="$LINE"
  run_sig "$work/s2.log" 'CI' 'fix/two';  s2="$SIG"
  run_sig "$work/s3.log" 'CI' 'fix/two';  s3="$SIG"
  ok; [ -n "$s1" ] && [ "$s1" = "$s2" ] || fail "volatile tokens leak into the signature ($s1 vs $s2): '$l1'"
  ok; [ -n "$s3" ] && [ "$s3" != "$s2" ] || fail "a meaningful difference must change the signature"
  assert_eq "$l1" 'Failed to fetch artifacts for https://github.com/o/r/actions/runs/<id> at <id> (refs/heads/<branch>) into <path> via <path> at <ts>' "normalised line"

  # No usable line: dedup is off, not wrong.
  CASE_NAME='no-logs'
  printf 'Could not retrieve logs\n' > "$work/none.log"
  run_sig "$work/none.log" 'CI' 'x'
  assert_eq "$RC" 0 "exit code"
  assert_eq "$SIG" '' "signature"
  assert_eq "$SRC" none "source"
  CASE_NAME='missing-log-file'
  run_sig '' 'CI' 'x'
  assert_eq "$RC" 0 "exit code"
  assert_eq "$SIG" '' "signature"
fi

# ------------------------------------------------------------------ gh stub
# Written with an explicit chmod: a non-executable file on PATH is skipped and
# the REAL gh would run against a live repository.
mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf 'STUB-GH-SENTINEL %s\n' "$*" >> "$GH_STUB_CALLS"
case "$1 ${2:-}" in
  "issue list")
    if [ "${GH_STUB_LIST_FAIL:-0}" = 1 ]; then echo 'HTTP 502: Bad Gateway' >&2; exit 1; fi
    cat "$GH_STUB_ISSUES" ;;
  "issue comment")
    printf '%s\n' "$@" > "$GH_STUB_CALLS.comment"
    exit "${GH_STUB_COMMENT_RC:-0}" ;;
  "label create")
    case "${GH_STUB_LABELS:-missing}" in
      exists) printf 'label with name "%s" already exists; use `--force` to update its color and description\n' "$3" >&2; exit 1 ;;
      fail) echo 'HTTP 403: Resource not accessible by integration' >&2; exit 1 ;;
      *) exit 0 ;;
    esac ;;
  *) echo "stub gh: unexpected call: $*" >&2; exit 97 ;;
esac
STUB
chmod +x "$work/bin/gh"
export PATH="$work/bin:$PATH"
# Fatal, not a counted failure: past this point a real gh would comment on a
# real issue. The repo name is also one GitHub cannot have (owners take no '.').
if [ "$(command -v gh)" != "$work/bin/gh" ]; then
  echo "FATAL: gh resolves to '$(command -v gh)', not the stub; refusing to run the lookup cases" >&2
  exit 1
fi
FAKE_REPO=harness.invalid/stub

# -------------------------------------------------------------------- lookup
SIG_A=0123456789ab
marker() { printf '<!-- auto-fix-signature: %s -->' "$1"; }

run_lookup() { # <case> <issues json> <signature> <max open> <pr number>
  CASE_NAME="lookup/$1"
  rm -rf "$work/run"
  mkdir -p "$work/run"
  printf '%s' "$2" > "$work/run/issues.json"
  : > "$work/run/output"
  : > "$work/run/calls"
  set +e
  GH_STUB_CALLS="$work/run/calls" GH_STUB_ISSUES="$work/run/issues.json" \
  GITHUB_OUTPUT="$work/run/output" GITHUB_REPOSITORY="$FAKE_REPO" GITHUB_SERVER_URL=https://github.com \
  SIGNATURE="$3" MAX_OPEN="$4" PR_NUMBER="$5" RUN_ID=123456789 BRANCH=feat/x WORKFLOW_NAME='Smoke Test CI' \
    bash "$work/lookup.sh" > "$work/run/stdout" 2> "$work/run/stderr"
  RC=$?
  set -e
  MODE="$(sed -n 's/^mode=//p' "$work/run/output")"
  ISSUE="$(sed -n 's/^issue_number=//p' "$work/run/output")"
  OPEN="$(sed -n 's/^open_auto_fix_issues=//p' "$work/run/output")"
  DIRECTIVE="$(awk '/^directive<<AUTO_FIX_DIRECTIVE_EOF$/ { f = 1; next } /^AUTO_FIX_DIRECTIVE_EOF$/ { f = 0 } f' "$work/run/output")"
  CALLS="$(cat "$work/run/calls")"
  COMMENT="$(cat "$work/run/calls.comment" 2>/dev/null || true)"
  STDOUT="$(cat "$work/run/stdout")"
}
listed() { assert_contains "$CALLS" "STUB-GH-SENTINEL issue list --repo $FAKE_REPO --state open" "gh calls"; }

if [ "$have_lookup" = 1 ]; then
  CASE_NAME='lookup-env'
  assert_env_binds "$LOOKUP_STEP" SIGNATURE MAX_OPEN PR_NUMBER RUN_ID BRANCH WORKFLOW_NAME

  run_lookup match "[{\"number\":7,\"body\":\"analysis\\n$(marker $SIG_A)\"},{\"number\":9,\"body\":\"$(marker ffffffffffff)\"},{\"number\":3,\"body\":null}]" "$SIG_A" 5 42
  assert_eq "$RC" 0 "exit code"; listed
  assert_eq "$MODE" existing "mode"
  assert_eq "$ISSUE" 7 "issue_number"
  assert_contains "$COMMENT" 'comment' "comment call"
  assert_contains "$COMMENT" $'\n7\n' "commented issue"
  assert_contains "$COMMENT" "https://github.com/$FAKE_REPO/actions/runs/123456789" "comment body"
  assert_contains "$COMMENT" 'feat/x' "comment body"
  assert_contains "$COMMENT" '#42' "comment body"
  assert_contains "$DIRECTIVE" '#7' "directive"
  assert_contains "$DIRECTIVE" 'Do NOT create' "directive"
  assert_contains "$DIRECTIVE" 'gh pr comment 42' "directive"
  assert_lacks "$DIRECTIVE" 'gh issue create' "directive"

  run_lookup oldest-wins "[{\"number\":12,\"body\":\"$(marker $SIG_A)\"},{\"number\":7,\"body\":\"$(marker $SIG_A)\"}]" "$SIG_A" 5 42
  assert_eq "$ISSUE" 7 "issue_number"

  run_lookup create "[{\"number\":9,\"body\":\"$(marker ffffffffffff)\"},{\"number\":4,\"body\":\"unrelated\"}]" "$SIG_A" 2 42
  assert_eq "$RC" 0 "exit code"; listed
  assert_eq "$MODE" create "mode"
  assert_eq "$ISSUE" '' "issue_number"
  assert_eq "$OPEN" 1 "open_auto_fix_issues"
  assert_contains "$DIRECTIVE" "$(marker $SIG_A)" "directive"
  assert_contains "$DIRECTIVE" 'gh issue create' "directive"
  assert_contains "$DIRECTIVE" '--label "bug,ci-failure"' "directive"
  assert_eq "$COMMENT" '' "comment call"

  # Flood guard: at the limit, not above it. max 2 with 2 open = paused.
  two_open="[{\"number\":9,\"body\":\"$(marker ffffffffffff)\"},{\"number\":10,\"body\":\"$(marker eeeeeeeeeeee)\"}]"
  run_lookup capped "$two_open" "$SIG_A" 2 42
  assert_eq "$RC" 0 "exit code"
  assert_eq "$MODE" capped "mode"
  assert_eq "$OPEN" 2 "open_auto_fix_issues"
  assert_contains "$DIRECTIVE" 'Do NOT create' "directive"
  assert_lacks "$DIRECTIVE" 'gh issue create' "directive"
  assert_contains "$STDOUT" '::warning::' "stdout"
  run_lookup below-cap "$two_open" "$SIG_A" 3 42
  assert_eq "$MODE" create "mode"

  run_lookup match-beats-cap "[{\"number\":7,\"body\":\"$(marker $SIG_A)\"}]" "$SIG_A" 0 42
  assert_eq "$MODE" existing "mode"

  run_lookup no-signature "[{\"number\":7,\"body\":\"$(marker $SIG_A)\"}]" '' 5 42
  assert_eq "$RC" 0 "exit code"
  assert_eq "$MODE" create "mode"
  assert_lacks "$DIRECTIVE" 'auto-fix-signature' "directive"
  assert_eq "$COMMENT" '' "comment call"

  GH_STUB_LIST_FAIL=1 run_lookup list-fails '[]' "$SIG_A" 2 42
  assert_eq "$RC" 0 "exit code"
  assert_eq "$MODE" create "mode"
  assert_contains "$STDOUT" '::warning::' "stdout"

  GH_STUB_COMMENT_RC=1 run_lookup comment-fails "[{\"number\":7,\"body\":\"$(marker $SIG_A)\"}]" "$SIG_A" 5 42
  assert_eq "$RC" 0 "exit code"
  assert_eq "$MODE" existing "mode"
  assert_contains "$STDOUT" '::warning::' "stdout"

  run_lookup bad-max '[]' "$SIG_A" two 42
  ok; [ "$RC" != 0 ] || fail "a non-integer max_auto_fix_prs must fail the step"
  assert_contains "$STDOUT" '::error::' "stdout"

  run_lookup no-pr '[]' "$SIG_A" 2 ''
  assert_eq "$MODE" create "mode"
  assert_lacks "$DIRECTIVE" 'gh pr comment' "directive"
  run_lookup pr-not-a-number '[]' "$SIG_A" 2 '42; echo'
  assert_lacks "$DIRECTIVE" 'gh pr comment' "directive"
  assert_lacks "$DIRECTIVE" 'echo' "directive"
fi

# -------------------------------------------------------------------- labels
run_labels() { # <case> <stub mode>
  CASE_NAME="labels/$1"
  rm -rf "$work/run"
  mkdir -p "$work/run"
  : > "$work/run/calls"
  set +e
  GH_STUB_CALLS="$work/run/calls" GH_STUB_LABELS="$2" GITHUB_REPOSITORY="$FAKE_REPO" LABEL_COLOR="$LABEL_COLOR" \
    bash "$work/labels.sh" > "$work/run/stdout" 2> "$work/run/stderr"
  RC=$?
  set -e
  CALLS="$(cat "$work/run/calls")"
  STDOUT="$(cat "$work/run/stdout")"
}

if [ "$have_label" = 1 ]; then
  # The colour is taken from the step, and must be a YAML string: an unquoted
  # all-digit colour such as 5319e7 parses as a float, and `gh label create`
  # rejects the float's rendering with HTTP 422.
  CASE_NAME='labels-env'
  LABEL_COLOR="$(step_field "$LABEL_STEP" .env.LABEL_COLOR)"
  assert_eq "$(STEP="$LABEL_STEP" yq -r '.jobs["auto-fix"].steps[] | select(.name == strenv(STEP)) | .env.LABEL_COLOR | tag' "$WORKFLOW")" '!!str' "LABEL_COLOR YAML tag"
  ok; printf '%s' "$LABEL_COLOR" | grep -qE '^[0-9a-fA-F]{6}$' || fail "LABEL_COLOR '$LABEL_COLOR' is not a 6-digit hex colour"

  run_labels missing missing
  assert_eq "$RC" 0 "exit code"
  assert_contains "$CALLS" "STUB-GH-SENTINEL label create bug --repo $FAKE_REPO" "gh calls"
  assert_contains "$CALLS" "STUB-GH-SENTINEL label create ci-failure --repo $FAKE_REPO" "gh calls"
  assert_lacks "$CALLS" '--force' "gh calls (create-if-missing must not recolour a shared label)"
  assert_contains "$STDOUT" 'created label: ci-failure' "stdout"

  run_labels present exists
  assert_eq "$RC" 0 "exit code"
  assert_contains "$STDOUT" 'label present: ci-failure' "stdout"
  assert_lacks "$STDOUT" '::warning::' "stdout"

  run_labels forbidden fail
  assert_eq "$RC" 0 "exit code"
  assert_contains "$STDOUT" "::warning::could not provision label 'ci-failure'" "stdout"
fi

# -------------------------------------------------------------------- report
if [ "$failures" -eq 0 ]; then
  printf 'auto-fix-dedup: %d assertion(s) passed.\n' "$checks"
else
  printf 'auto-fix-dedup: %d assertion(s) FAILED out of %d.\n' "$failures" "$checks"
  exit 1
fi

#!/usr/bin/env bash
# Fixtures for reusable-merge-method.yml's `Publish check run and label` step.
#
# EXTRACTS the shipped step body with yq (no retyped copy) and runs it per case
# against a stub `gh` that logs every call and answers the label reads. The
# decision script itself is tested in laurigates/claude-plugins
# (git-plugin/scripts/tests/test-pr-merge-method.sh); each case here feeds a
# canned KEY=VALUE result and checks only what this step adds: the check run's
# title and conclusion, the label swap, the override hands-off, a missing label
# not failing the run, and a script ERROR failing it after posting a neutral
# check run.
#
# Usage: bash .github/tests/merge-method/run.sh
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

WF=.github/workflows/reusable-merge-method.yml
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

command -v yq >/dev/null || { echo "FATAL: yq (mikefarah) is required" >&2; exit 1; }

failures=0
checks=0
fail() { printf '  FAIL [%s] %s\n' "$CASE" "$1"; failures=$((failures + 1)); }
ok() { checks=$((checks + 1)); }

yq -e '.jobs.classify.steps[] | select(.name == "Publish check run and label") | .run' "$WF" >"$work/step.sh"
[ -s "$work/step.sh" ] || { echo "FATAL: publish step not found in $WF" >&2; exit 1; }
# A body containing ${{ }} would be an expression the runner expands before bash
# sees it; every input must arrive through env:.
if grep -q '\${{' "$work/step.sh"; then echo "FATAL: publish step body contains \${{ }}" >&2; exit 1; fi

mkdir -p "$work/bin"
cat >"$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
# Log the call; a check-run POST also logs its JSON body from stdin.
printf '%s\n' "$*" >>"$GH_LOG"
case "$*" in
  *check-runs*) cat >>"$GH_LOG"; echo "https://example.test/check" ;;
  "api repos/o/r/issues/5/labels --jq .[].name") printf '%s' "${STUB_LABELS:-}" ;;
  "api repos/o/r/labels/"*) [ "${STUB_LABEL_MISSING:-0}" = 0 ] || exit 1 ;;
esac
exit 0
EOF
chmod +x "$work/bin/gh"
[ -x "$work/bin/gh" ] || { echo "FATAL: stub gh not executable" >&2; exit 1; }

# run_case <name> <result-file-content>; sets RC, LOG, OUT
run_case() {
  CASE=$1
  printf '%s\n' "$2" >"$work/result.txt"
  : >"$work/gh.log"
  RC=0
  OUT=$(PATH="$work/bin:$PATH" GH_LOG="$work/gh.log" REPO=o/r PR=5 HEAD_SHA=abc RESULT="$work/result.txt" \
    bash "$work/step.sh" 2>&1) || RC=$?
  LOG=$(cat "$work/gh.log")
}
has() { if grep -qF -- "$1" <<<"$LOG"; then ok; else fail "gh log lacks: $1"; fi; }
lacks() { if grep -qF -- "$1" <<<"$LOG"; then fail "gh log has: $1"; else ok; fi; }
rc_is() { if [ "$RC" -eq "$1" ]; then ok; else fail "exit $RC, want $1: $OUT"; fi; }

REBASE='METHOD=rebase
RULE=9
REASON=independent_commits
DETAIL=3 independent conventional commits
OVERRIDE=none
TITLE=→ Rebase and merge (3 independent conventional commits)
COMMITS=3
SQUASH_BODY=PR_BODY
BODY_LINT=0
STATUS=OK'

run_case rebase-fresh "$REBASE"
rc_is 0
has '"title":"→ Rebase and merge (3 independent conventional commits)"'
has '"conclusion":"success"'
has '"head_sha":"abc"'
has 'labels[]=merge:rebase'
lacks 'DELETE'

STUB_LABELS=$'merge:squash\nbug' run_case rebase-swaps-label "$REBASE"
rc_is 0
has 'api -X DELETE repos/o/r/issues/5/labels/merge:squash'
has 'labels[]=merge:rebase'

STUB_LABELS='merge:rebase' run_case rebase-already-labelled "$REBASE"
rc_is 0
lacks 'labels[]='
lacks 'DELETE'

run_case squash-with-lint 'METHOD=squash
RULE=8
REASON=in_pr_correction
DETAIL=2f699f5 fix(x): y corrects in-PR work from c2139ec
OVERRIDE=none
TITLE=→ Squash and merge (in-PR fixup) · body: 2 lint issues
COMMITS=2
SQUASH_BODY=PR_BODY
BODY_LINT=2
LINT_CHECKLIST=1
LINT_HEADING=1
STATUS=WARN'
rc_is 0
has '"conclusion":"neutral"'
has '- `CHECKLIST`: 1'
has 'labels[]=merge:squash'

STUB_LABELS='merge:squash' run_case override-hands-off 'METHOD=squash
RULE=1
REASON=override_label
DETAIL=merge:squash applied by a human
OVERRIDE=merge:squash
TITLE=→ Squash and merge (label override)
COMMITS=4
SQUASH_BODY=PR_BODY
BODY_LINT=0
STATUS=OK'
rc_is 0
has 'Overridden by the human-applied'
lacks 'issues/5/labels'

STUB_LABEL_MISSING=1 run_case label-missing "$REBASE"
rc_is 0
has 'check-runs'
lacks 'labels[]='
if grep -q '::warning::label merge:rebase does not exist' <<<"$OUT"; then ok; else fail "no missing-label warning: $OUT"; fi

run_case script-error 'METHOD=unknown
STATUS=ERROR
REASON=fetch_failed: gh api graphql failed'
rc_is 1
has '"title":"Merge method unknown"'
has '"conclusion":"neutral"'
lacks 'labels[]='

run_case empty-result ''
rc_is 0
has '"title":"Merge method unknown"'
lacks 'labels[]='

if [ "$failures" -ne 0 ]; then
  printf 'merge-method: %d failure(s) in %d assertion(s)\n' "$failures" "$((checks + failures))"
  exit 1
fi
printf 'PASS: merge-method (%d assertion(s))\n' "$checks"

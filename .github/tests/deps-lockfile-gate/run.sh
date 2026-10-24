#!/usr/bin/env bash
# Regression test: reusable-security-deps.yml must run Claude only when a
# lockfile changed.
#
# `Check for lockfile changes` computed has_lockfiles and nothing read it.
# The analysis step was gated on the audit output alone, which is never empty
# (every audit branch writes its output, error text included), so Claude ran
# on every PR. The list also lacked bun.lock and uv.lock.
#
# Checks the analysis step's if: with yq, then EXTRACTS the shipped step body
# and runs it on scratch repositories as a pull_request against main.
#
# Usage: bash .github/tests/deps-lockfile-gate/run.sh [workflow-file]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

NAME=deps-lockfile-gate
WORKFLOW="${1:-.github/workflows/reusable-security-deps.yml}"
command -v yq >/dev/null || { echo "FATAL: yq (mikefarah) is required" >&2; exit 1; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0
checks=0
fail() { printf '  FAIL [%s] %s\n' "$CASE" "$1"; failures=$((failures + 1)); }
ok()   { checks=$((checks + 1)); }

export GIT_CONFIG_GLOBAL="$work/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --file "$GIT_CONFIG_GLOBAL" user.name fixture
git config --file "$GIT_CONFIG_GLOBAL" user.email fixture@example.invalid
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
git config --file "$GIT_CONFIG_GLOBAL" core.hooksPath /dev/null

CASE=wiring
GATE="steps.changed.outputs.has_lockfiles == 'true'"
analyze_if="$(yq '[.jobs.*.steps[] | select(.id == "analyze")] | .[0].if // ""' "$WORKFLOW")"
ok
case "$analyze_if" in
  *"||"*) fail "analyze if: carries ||, so the lockfile gate is not a required operand: $analyze_if" ;;
  *"$GATE"*) ;;
  *) fail "analyze if: does not require \"$GATE\": $analyze_if" ;;
esac

yq '[.jobs.*.steps[] | select(.id == "changed")] | .[0].run' "$WORKFLOW" > "$work/step.sh"
ok
[ -s "$work/step.sh" ] || fail "no run: body for the step with id 'changed'"

# run_case <name> <expect true|false> <path...>: a PR that adds each <path>.
run_case() {
  CASE="$1"
  local want="$2" dir="$work/repo-$1" p
  shift 2
  git init -q "$dir"
  printf 'readme\n' > "$dir/README.md"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m base
  git -C "$dir" update-ref refs/remotes/origin/main HEAD
  for p in "$@"; do
    mkdir -p "$dir/$(dirname "$p")"
    printf 'x\n' >> "$dir/$p"
  done
  git -C "$dir" add -A
  git -C "$dir" commit -q -m pr
  : > "$work/out"
  rc=0
  (cd "$dir" && EVENT_NAME=pull_request BASE_REF=main MAX_DIFF_LINES=0 GITHUB_OUTPUT="$work/out" bash "$work/step.sh") \
    > "$work/stdout" 2>&1 || rc=$?
  ok; [ "$rc" = 0 ] || fail "step exited $rc: $(head -c 200 "$work/stdout")"
  ok; grep -qx "has_lockfiles=$want" "$work/out" || fail "expected has_lockfiles=$want, got: $(tr '\n' ' ' < "$work/out")"
}

run_case readme-only false README.md
run_case source-only false src/app.ts
run_case npm true package-lock.json
run_case bun-text true bun.lock
run_case uv true uv.lock
run_case nested-cargo true crates/x/Cargo.lock

if [ "$failures" -ne 0 ]; then
  printf 'FAIL: %s (%d of %d assertion(s) failed)\n' "$NAME" "$failures" "$checks"
  exit 1
fi
printf 'PASS: %s (%d assertion(s))\n' "$NAME" "$checks"

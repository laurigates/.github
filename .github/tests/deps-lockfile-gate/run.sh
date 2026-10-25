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
# Claude must also run only when the audit reports vulnerabilities. A
# zero-vulnerability report went to Claude, and so did the error text of an
# audit that never ran: every branch wrote `> audit-results.json 2>&1`, which
# also made the file invalid JSON whenever the tool printed to stderr
# (pip-audit does on every run). The test runs the extracted audit step with
# stub tools, to pin that stderr stays out of the results file, and the
# extracted 'Count audit vulnerabilities' step against fixtures/, which is
# real stdout from npm 11.20.0, pnpm 10.34.8, yarn 1.22.22, bun 1.4.4,
# pip-audit 2.10.1 and cargo-audit 0.22.2: minimist 1.2.5 (npm, pnpm, yarn,
# bun), jinja2 3.1.3 (pip) and smallvec 1.6.0 (cargo) for the vulnerable
# reports, a clean pin for the clean ones, npm and pnpm with no lockfile for
# the error objects, and `2>&1` captures of bun without a lockfile and of a
# clean pip-audit run (*.txt) for the mixed-stream case.
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

# ------------------------------------------------- audit output and count
# The analysis also needs a vulnerability count above 0 from 'Count audit
# vulnerabilities'. Before it, a zero-vulnerability report and an audit's
# error text both reached Claude as results.
CASE=count-wiring
COUNT_GATE="steps.audit-count.outputs.count > 0"
ok
case "$analyze_if" in
  *"$COUNT_GATE"*) ;;
  *) fail "analyze if: does not require \"$COUNT_GATE\": $analyze_if" ;;
esac
count_if="$(yq '[.jobs.*.steps[] | select(.id == "audit-count")] | .[0].if // ""' "$WORKFLOW")"
for operand in "steps.changed.outputs.has_lockfiles == 'true'" "steps.changed.outputs.skip != 'true'" "steps.actor.outputs.allowed == 'true'"; do
  ok
  case "$count_if" in
    *"||"*) fail "audit-count if: carries ||: $count_if" ;;
    *"$operand"*) ;;
    *) fail "audit-count if: does not require \"$operand\": $count_if" ;;
  esac
done
ok
# shellcheck disable=SC2016 # literal ${{ }} expressions
[ "$(yq '[.jobs.*.steps[] | select(.id == "audit-count")] | .[0].env.AUDIT_OUTCOME // ""' "$WORKFLOW")" = '${{ steps.audit-cmd.outcome }}' ] \
  || fail "audit-count does not read steps.audit-cmd.outcome"
yq '[.jobs.*.steps[] | select(.id == "audit-count")] | .[0].run // ""' "$WORKFLOW" > "$work/count.sh"
ok; [ -s "$work/count.sh" ] || fail "no run: body for the step with id 'audit-count'"
ok
# shellcheck disable=SC2016
if grep -qF '${{' "$work/count.sh"; then fail "audit-count interpolates an expression into its run: body"; fi

# The audit step must keep stderr out of audit-results.json: pip-audit prints
# its summary there on every run, and npm, bun and cargo their errors. Its
# body is run with stub tools that print JSON on stdout and text on stderr;
# its one expression, the package-manager input, becomes $PM.
CASE=audit-stderr
yq '[.jobs.*.steps[] | select(.id == "audit-cmd")] | .[0].run // ""' "$WORKFLOW" \
  | sed 's/\${{ inputs\.package-manager }}/${PM}/' > "$work/audit.sh"
ok; [ -s "$work/audit.sh" ] || fail "no run: body for the step with id 'audit-cmd'"
ok
# shellcheck disable=SC2016
if grep -qF '${{' "$work/audit.sh"; then fail "audit-cmd has an expression besides inputs.package-manager"; fi
stubs="$work/stubs"
mkdir -p "$stubs"
for tool in npm bun pnpm yarn pip-audit cargo; do
  cat > "$stubs/$tool" <<STUB
#!/usr/bin/env bash
[ "\${1:-}" = install ] && exit 0
echo "$tool" >> "\$STUB_LOG"
echo '{"stub":"$tool"}'
echo "$tool-stub-stderr" >&2
exit 1
STUB
done
printf '#!/usr/bin/env bash\nexit 0\n' > "$stubs/pip"
chmod +x "$stubs"/*
for PM in npm bun pnpm yarn pip cargo; do
  CASE="audit-stderr-$PM"
  tool="$PM"
  [ "$PM" = pip ] && tool=pip-audit
  dir="$work/audit-$PM"
  mkdir -p "$dir"
  printf 'six==1.16.0\n' > "$dir/requirements.txt"
  : > "$work/audit-out"
  : > "$work/stub-log"
  rc=0
  (cd "$dir" && PM="$PM" PATH="$stubs:$PATH" STUB_LOG="$work/stub-log" GITHUB_OUTPUT="$work/audit-out" bash "$work/audit.sh") \
    > "$work/stdout" 2>&1 || rc=$?
  ok; [ "$rc" = 0 ] || fail "audit step exited $rc: $(head -c 200 "$work/stdout")"
  ok; grep -qx "$tool" "$work/stub-log" || fail "the $tool stub did not run, so the real tool may have"
  ok; [ "$(cat "$dir/audit-results.json" 2>/dev/null)" = "{\"stub\":\"$tool\"}" ] \
    || fail "audit-results.json is not the stub's stdout alone: $(head -c 200 "$dir/audit-results.json" 2>/dev/null)"
  ok; grep -qx "$tool-stub-stderr" "$dir/audit-stderr.log" 2>/dev/null || fail "the stub's stderr did not reach audit-stderr.log"
done

# The count step against real audit output (fixtures/, see the header).
FIX="$PWD/.github/tests/deps-lockfile-gate/fixtures"
# count_case <name> <package-manager> <fixture|-|none> <outcome> <want>
#   fixture '-' writes an empty results file, 'none' writes no file.
#   want: a number (count=N, exit 0), skip (exit 0, no count) or fail (exit 1
#   with an ::error:: line and no count).
count_case() {
  CASE="count-$1"
  local pm="$2" fixture="$3" outcome="$4" want="$5" dir="$work/count-$1"
  mkdir -p "$dir"
  case "$fixture" in
    -) : > "$dir/audit-results.json" ;;
    none) ;;
    *) cp "$FIX/$fixture" "$dir/audit-results.json" ;;
  esac
  printf 'audit stderr line\n' > "$dir/audit-stderr.log"
  : > "$work/count-out"
  rc=0
  (cd "$dir" && PACKAGE_MANAGER="$pm" AUDIT_OUTCOME="$outcome" GITHUB_OUTPUT="$work/count-out" bash "$work/count.sh") \
    > "$work/stdout" 2>&1 || rc=$?
  case "$want" in
    fail)
      ok; [ "$rc" = 1 ] || fail "expected exit 1, got $rc: $(head -c 200 "$work/stdout")"
      ok; grep -q '^::error::Dependency Security Audit: ' "$work/stdout" || fail "no ::error:: line: $(head -c 200 "$work/stdout")"
      ok; if grep -q '^count=' "$work/count-out"; then fail "wrote a count on a failed audit: $(cat "$work/count-out")"; fi
      ;;
    skip)
      ok; [ "$rc" = 0 ] || fail "expected exit 0, got $rc: $(head -c 200 "$work/stdout")"
      ok; if grep -q '^count=' "$work/count-out"; then fail "wrote a count with no results file: $(cat "$work/count-out")"; fi
      ;;
    *)
      ok; [ "$rc" = 0 ] || fail "expected exit 0, got $rc: $(head -c 300 "$work/stdout")"
      ok; [ "$(cat "$work/count-out")" = "count=$want" ] || fail "expected count=$want, got: $(tr '\n' ' ' < "$work/count-out")"
      ;;
  esac
}

count_case npm-vuln         npm   npm-vuln.json           success 1
count_case npm-clean        npm   npm-clean.json          success 0
count_case npm-enolock      npm   npm-enolock.json        success fail
count_case pnpm-vuln        pnpm  pnpm-vuln.json          success 1
count_case pnpm-clean       pnpm  pnpm-clean.json         success 0
count_case pnpm-nolock      pnpm  pnpm-nolock.json        success fail
count_case yarn-vuln        yarn  yarn-vuln.ndjson        success 1
count_case yarn-clean       yarn  yarn-clean.ndjson       success 0
count_case bun-vuln         bun   bun-vuln.json           success 1
count_case bun-clean        bun   bun-clean.json          success 0
count_case bun-nolock       bun   -                       success fail
count_case bun-stderr-mixed bun   bun-nolock-combined.txt success fail
count_case pip-vuln         pip   pip-vuln.json           success 8
count_case pip-clean        pip   pip-clean.json          success 0
count_case pip-stderr-mixed pip   pip-clean-combined.txt  success fail
count_case cargo-vuln       cargo cargo-vuln.json         success 1
count_case cargo-clean      cargo cargo-clean.json        success 0
# A report in another manager's shape has no count where this one looks.
count_case cargo-as-npm     npm   cargo-clean.json        success fail
count_case npm-as-pip       pip   npm-clean.json          success fail
count_case yarn-as-npm      npm   yarn-vuln.ndjson        success fail
count_case audit-failed     cargo cargo-clean.json        failure fail
count_case outcome-unset    npm   npm-clean.json          ''      fail
count_case unknown-manager  poetry npm-clean.json         success fail
count_case no-results-file  pip   none                    success skip

if [ "$failures" -ne 0 ]; then
  printf 'FAIL: %s (%d of %d assertion(s) failed)\n' "$NAME" "$failures" "$checks"
  exit 1
fi
printf 'PASS: %s (%d assertion(s))\n' "$NAME" "$checks"

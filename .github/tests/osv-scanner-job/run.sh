#!/usr/bin/env bash
# Test for the osv-scanner job in reusable-security-deps.yml.
#
# EXTRACTS the job's shipped `Scan dependencies` body with yq and runs it in
# scratch repositories against a stub osv-scanner, so the lockfile gate, the
# exit-code handling, the rendering and the fail-on-high gate are exercised
# without network access. fixtures/lodash-4.17.20.json is real
# `osv-scanner scan source --format json` output (2.7.0) for a lockfile
# pinning lodash 4.17.20, cut to the fields the step reads; @ROOT@ stands for
# the scanned directory, which osv-scanner reports as an absolute path.
#
# On Linux x86_64 (CI) it also runs the shipped install step, which checks the
# pinned SHA256, and asks the installed binary for its version.
#
# Usage: bash .github/tests/osv-scanner-job/run.sh [workflow-file]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

NAME=osv-scanner-job
WORKFLOW="${1:-.github/workflows/reusable-security-deps.yml}"
FIXTURE="$PWD/.github/tests/osv-scanner-job/fixtures/lodash-4.17.20.json"
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

export GIT_CONFIG_GLOBAL="$work/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --file "$GIT_CONFIG_GLOBAL" user.name fixture
git config --file "$GIT_CONFIG_GLOBAL" user.email fixture@example.invalid
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
git config --file "$GIT_CONFIG_GLOBAL" core.hooksPath /dev/null

step() { STEP="$1" yq ".jobs[\"osv-scanner\"].steps[] | select(.name == strenv(STEP)) | $2 // \"\"" "$WORKFLOW"; }
INSTALL='Install osv-scanner'
SCAN='Scan dependencies'

# ------------------------------------------------------------------ wiring
CASE=wiring
ok; [ "$(yq '.jobs | has("osv-scanner")' "$WORKFLOW")" = true ] || { fail "no 'osv-scanner' job"; echo "FAIL: $NAME"; exit 1; }
ok; [ "$(yq '.jobs["osv-scanner"] | has("if")' "$WORKFLOW")" = false ] || fail "the osv-scanner job carries an if:"
ok; [ "$(yq '.jobs["osv-scanner"].permissions.contents' "$WORKFLOW")" = read ] || fail "permissions must be contents: read"
ok; [ "$(yq '.jobs["osv-scanner"].steps[0].with.persist-credentials' "$WORKFLOW")" = false ] || fail "checkout must set persist-credentials: false"
ok; [ "$(yq '[.jobs["osv-scanner"].steps[] | select(has("if"))] | length' "$WORKFLOW")" = 0 ] || fail "an osv-scanner step carries an if:"
ok
# shellcheck disable=SC2016 # literal ${{ }} expressions
[ "$(step "$SCAN" .env.FAIL_ON_HIGH)" = '${{ inputs.fail-on-high }}' ] || fail "the scan step does not read inputs.fail-on-high"
for s in "$INSTALL" "$SCAN"; do
  ok
  # shellcheck disable=SC2016
  if grep -qF '${{' <<<"$(step "$s" .run)"; then fail "'$s' interpolates an expression into its run: body"; fi
done
step "$SCAN" .run > "$work/scan.sh"
ok; [ -s "$work/scan.sh" ] || fail "no '$SCAN' run: body"

if [ "$(uname -s)/$(uname -m)" = Linux/x86_64 ]; then
  CASE=install
  step "$INSTALL" .run > "$work/install.sh"
  mkdir -p "$work/rt-install"
  : > "$work/rt-install/path"
  rc=0
  (
    while IFS=$'\t' read -r k v; do export "$k=$v"; done \
      < <(STEP="$INSTALL" yq -r '.jobs["osv-scanner"].steps[] | select(.name == strenv(STEP)) | .env | to_entries | .[] | .key + "\t" + .value' "$WORKFLOW")
    RUNNER_TEMP="$work/rt-install" GITHUB_PATH="$work/rt-install/path" bash "$work/install.sh"
  ) > "$work/install.log" 2>&1 || rc=$?
  ok; [ "$rc" = 0 ] || fail "the shipped install step failed (exit $rc): $(tail -c 300 "$work/install.log")"
  want="$(step "$INSTALL" .env.OSV_SCANNER_VERSION)"
  got="$("$(head -n1 "$work/rt-install/path")/osv-scanner" --version 2>&1 || true)"
  ok; grep -qF "$want" <<<"$got" || fail "installed osv-scanner reports '$(head -n1 <<<"$got")', the workflow pins $want"
fi

# ---------------------------------------------------------------- the stub
# A visible stub: it records a sentinel, writes STUB_RESULT (with @ROOT@
# replaced by the scanned directory, as the real tool reports absolute paths)
# to --output-file, and exits STUB_RC.
mkdir -p "$work/bin"
cat > "$work/bin/osv-scanner" <<'STUB'
#!/usr/bin/env bash
echo "STUB-OSV-SENTINEL $*" >> "$STUB_CALLS"
out=""
while [ "$#" -gt 0 ]; do
  case "$1" in --output-file) out="$2"; shift ;; esac
  shift
done
if [ -n "$out" ] && [ -n "${STUB_RESULT:-}" ]; then
  sed "s#@ROOT@#$PWD#g" "$STUB_RESULT" > "$out"
fi
exit "${STUB_RC:-0}"
STUB
chmod +x "$work/bin/osv-scanner"
EMPTY="$work/empty.json"
printf '{"results": []}\n' > "$EMPTY"

# run_scan <repo> <event> <stub rc> <stub result> <fail-on-high>
run_scan() {
  rm -rf "$work/rt" && mkdir -p "$work/rt"
  STUB_CALLS="$work/rt/calls"; : > "$STUB_CALLS"
  RC=0
  (cd "$1" && PATH="$work/bin:$PATH" STUB_CALLS="$STUB_CALLS" STUB_RC="$3" STUB_RESULT="$4" \
    EVENT_NAME="$2" BASE_REF=main FAIL_ON_HIGH="$5" RUNNER_TEMP="$work/rt" GITHUB_STEP_SUMMARY="$work/rt/summary.md" \
    bash "$work/scan.sh") > "$work/rt/out" 2>&1 || RC=$?
  OUT="$(cat "$work/rt/out")"
  SUMMARY="$(cat "$work/rt/summary.md" 2>/dev/null || true)"
  CALLED="$(grep -c STUB-OSV-SENTINEL "$STUB_CALLS" || true)"
}
rc_is()  { ok; [ "$RC" = "$1" ] || fail "expected exit $1, got $RC: $(head -c 400 <<<"$OUT")"; }
called() { ok; [ "$CALLED" = "$1" ] || fail "expected $1 osv-scanner call(s), got $CALLED"; }
has()    { ok; grep -qF -- "$1" <<<"$2" || fail "expected '$1' in: $(head -c 400 <<<"$2")"; }
count()  { ok; local n; n="$(grep -c -- "$1" <<<"$2" || true)"; [ "$n" = "$3" ] || fail "expected $3 line(s) matching '$1', got $n"; }

new_repo() { # <dir> <path changed in the PR>
  git init -q "$1"
  printf 'base\n' > "$1/README.md"
  git -C "$1" add -A
  git -C "$1" commit -q -m base
  git -C "$1" update-ref refs/remotes/origin/main HEAD
  mkdir -p "$1/$(dirname "$2")"
  printf 'x\n' >> "$1/$2"
  git -C "$1" add -A
  git -C "$1" commit -q -m pr
}
new_repo "$work/lock" package-lock.json
new_repo "$work/nolock" src/app.ts

CASE=pr-without-lockfile
run_scan "$work/nolock" pull_request 1 "$FIXTURE" false
rc_is 0; called 0
has '::notice::osv-scanner: no lockfile changed in this PR' "$OUT"

CASE=push-without-lockfile-change
run_scan "$work/nolock" push 0 "$EMPTY" false
rc_is 0; called 1

CASE=pr-advisories-report-only
run_scan "$work/lock" pull_request 1 "$FIXTURE" false
rc_is 0; called 1
count '^::warning file=package-lock.json::osv-scanner: lodash@4.17.20 has GHSA-' "$OUT" 5
has '::warning file=package-lock.json::osv-scanner: lodash@4.17.20 has GHSA-r5fr-rjxr-66jc (CVSS 8.1)' "$OUT"
has '**Advisories:** 5 · **CVSS 7.0 or higher:** 2' "$SUMMARY"
# shellcheck disable=SC2016 # the backticks are Markdown code spans
has '| `package-lock.json` | `lodash@4.17.20` (npm) | GHSA-r5fr-rjxr-66jc | 8.1 |' "$SUMMARY"

CASE=pr-advisories-fail-on-high
run_scan "$work/lock" pull_request 1 "$FIXTURE" true
rc_is 1
has '::error::osv-scanner: 2 advisory group(s) at CVSS 7.0 or higher, and fail-on-high is set.' "$OUT"

CASE=clean
run_scan "$work/lock" pull_request 0 "$EMPTY" true
rc_is 0
has '**Advisories:** 0' "$SUMMARY"

CASE=no-package-source
run_scan "$work/lock" pull_request 128 '' true
rc_is 0
has '::notice::osv-scanner: no lockfile or manifest it recognises' "$OUT"

CASE=scanner-error
run_scan "$work/lock" pull_request 127 '' false
rc_is 1
has '::error::osv-scanner exited 127; nothing was audited.' "$OUT"

if [ "$failures" -ne 0 ]; then
  printf 'FAIL: %s (%d of %d assertion(s) failed)\n' "$NAME" "$failures" "$checks"
  exit 1
fi
printf 'PASS: %s (%d assertion(s))\n' "$NAME" "$checks"

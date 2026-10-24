#!/usr/bin/env bash
# Behavioural test for the gitleaks job in reusable-security-secrets.yml.
#
# Two ways the job could pass while scanning nothing, both observed with
# gitleaks 8.30.1:
#
#   - a .gitleaks.toml with an [allowlist] but no `[extend] useDefault =
#     true` and no [[rules]] loads zero rules, and gitleaks then reports "no
#     leaks found" on a planted key (mcu-tinkering-lab's config is one);
#   - `gitleaks git --log-opts=<range>` on a range that resolves to no commits,
#     a missing base ref included, exits 0 with "0 commits scanned".
#
# The test EXTRACTS the job's shipped step bodies with yq and runs them in
# scratch repositories. On Linux x86_64 (CI) it gets gitleaks by running the
# shipped install step, which also checks the pinned SHA256; elsewhere it
# needs gitleaks on PATH.
#
# Usage: bash .github/tests/gitleaks-guard/run.sh [workflow-file]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

NAME=gitleaks-guard
WORKFLOW="${1:-.github/workflows/reusable-security-secrets.yml}"
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

step() { STEP="$1" yq ".jobs.gitleaks.steps[] | select(.name == strenv(STEP)) | $2 // \"\"" "$WORKFLOW"; }
INSTALL='Install gitleaks'
CANARY='Prove the gitleaks config detects a planted key'
SCAN='Scan the change for secrets'

# ------------------------------------------------------------------ wiring
CASE=wiring
ok; [ "$(yq '.jobs | has("gitleaks")' "$WORKFLOW")" = true ] || { fail "no 'gitleaks' job"; echo "FAIL: $NAME"; exit 1; }
ok; [ "$(yq '.jobs.gitleaks | has("if")' "$WORKFLOW")" = false ] \
  || fail "the gitleaks job carries an if:; it must run for every actor and event"
ok; [ "$(yq '.jobs.gitleaks.permissions.contents' "$WORKFLOW")" = read ] || fail "gitleaks job permissions must be contents: read"
ok; [ "$(yq '.jobs.gitleaks.steps[0].with.fetch-depth' "$WORKFLOW")" = 0 ] || fail "checkout needs fetch-depth: 0 to scan the PR's commits"
ok; [ "$(yq '.jobs.gitleaks.steps[0].with.persist-credentials' "$WORKFLOW")" = false ] || fail "checkout must set persist-credentials: false"
names="$(yq -r '.jobs.gitleaks.steps[].name' "$WORKFLOW")"
pos() { grep -nxF -- "$1" <<<"$names" | cut -d: -f1 || true; }
p_i="$(pos "$INSTALL")"; p_c="$(pos "$CANARY")"; p_s="$(pos "$SCAN")"
ok; [ -n "$p_i" ] && [ -n "$p_c" ] && [ -n "$p_s" ] && [ "$p_i" -lt "$p_c" ] && [ "$p_c" -lt "$p_s" ] \
  || fail "steps must run install < config check < scan (got ${p_i:-?} ${p_c:-?} ${p_s:-?})"
ok; [ "$(yq '[.jobs.gitleaks.steps[] | select(has("if"))] | length' "$WORKFLOW")" = 0 ] \
  || fail "a gitleaks step carries an if:, so the config check or the scan can be skipped"
for s in "$INSTALL" "$CANARY" "$SCAN"; do
  ok
  # shellcheck disable=SC2016 # a literal ${{, not a shell expansion
  if grep -qF '${{' <<<"$(step "$s" .run)"; then fail "'$s' interpolates an expression into its run: body"; fi
done
step "$CANARY" .run > "$work/canary.sh"
step "$SCAN" .run > "$work/scan.sh"

# ------------------------------------------------------------- the binary
CASE=install
mkdir -p "$work/rt"
if [ "$(uname -s)/$(uname -m)" = Linux/x86_64 ]; then
  step "$INSTALL" .run > "$work/install.sh"
  : > "$work/rt/path"
  rc=0
  (
    while IFS=$'\t' read -r k v; do export "$k=$v"; done \
      < <(STEP="$INSTALL" yq -r '.jobs.gitleaks.steps[] | select(.name == strenv(STEP)) | .env | to_entries | .[] | .key + "\t" + .value' "$WORKFLOW")
    RUNNER_TEMP="$work/rt" GITHUB_PATH="$work/rt/path" bash "$work/install.sh"
  ) > "$work/install.log" 2>&1 || rc=$?
  ok; [ "$rc" = 0 ] || fail "the shipped install step failed (exit $rc): $(tail -c 300 "$work/install.log")"
  PATH="$(head -n1 "$work/rt/path"):$PATH"
fi
if ! command -v gitleaks >/dev/null; then
  echo "FATAL: gitleaks is not on PATH (install it, e.g. mise use -g aqua:gitleaks/gitleaks)" >&2
  exit 1
fi
want="$(STEP="$INSTALL" yq '.jobs.gitleaks.steps[] | select(.name == strenv(STEP)) | .env.GITLEAKS_VERSION' "$WORKFLOW")"
got="$(gitleaks version 2>/dev/null || true)"
ok; [ "$got" = "$want" ] || fail "gitleaks on PATH is '$got', the workflow pins '$want'"

# A key built at run time, so no literal key sits in this file.
fresh_key() { local r; r="$(head -c 20 /dev/urandom | base32 | tr -d '=\n')"; printf 'AKIA%s' "${r:0:16}"; }

# new_repo <dir>: a base commit on main, tracked as origin/main.
new_repo() {
  git init -q "$1"
  printf 'base\n' > "$1/README.md"
  git -C "$1" add -A
  git -C "$1" commit -q -m base
  git -C "$1" update-ref refs/remotes/origin/main HEAD
}
commit_file() { # <dir> <path> <content>
  mkdir -p "$1/$(dirname "$2")"
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add -A
  git -C "$1" commit -q -m "edit $2"
}

ZERO_RULE=$'[allowlist]\ndescription = "allowlist only"\npaths = [\'\'\'^docs/\'\'\']'
USE_DEFAULT=$'[extend]\nuseDefault = true\n\n[allowlist]\npaths = [\'\'\'^docs/\'\'\']'

# run_canary <repo>: sets RC, OUT (stdout), ENVF (GITHUB_ENV file).
run_canary() {
  rm -rf "$work/rt/c" && mkdir -p "$work/rt/c"
  ENVF="$work/rt/c/env"; : > "$ENVF"
  RC=0
  (cd "$1" && env -u GITLEAKS_CONFIG RUNNER_TEMP="$work/rt/c" GITHUB_ENV="$ENVF" bash "$work/canary.sh") \
    > "$work/rt/c/out" 2>&1 || RC=$?
  OUT="$(cat "$work/rt/c/out")"
}
# run_scan <repo> <event> [KEY=VALUE...]: the GITHUB_ENV the canary wrote is
# loaded first, as the runner would. Sets RC, OUT, SUMMARY.
run_scan() {
  local repo="$1" event="$2"
  shift 2
  rm -rf "$work/rt/s" && mkdir -p "$work/rt/s"
  RC=0
  (
    cd "$repo"
    unset GITLEAKS_CONFIG
    if [ -s "${ENVF:-/dev/null}" ]; then
      while IFS='=' read -r k v; do export "$k=$v"; done < "$ENVF"
    fi
    env EVENT_NAME="$event" BASE_REF=main BEFORE='' AFTER="$(git rev-parse HEAD)" "$@" \
      RUNNER_TEMP="$work/rt/s" GITHUB_STEP_SUMMARY="$work/rt/s/summary.md" bash "$work/scan.sh"
  ) > "$work/rt/s/out" 2>&1 || RC=$?
  OUT="$(cat "$work/rt/s/out")"
  SUMMARY="$(cat "$work/rt/s/summary.md" 2>/dev/null || true)"
}
has()   { ok; grep -qF -- "$1" <<<"$2" || fail "expected '$1' in: $(head -c 400 <<<"$2")"; }
lacks() { ok; if grep -qF -- "$1" <<<"$2"; then fail "did not expect '$1' in output"; fi; }
rc_is() { ok; [ "$RC" = "$1" ] || fail "expected exit $1, got $RC: $(head -c 400 <<<"$OUT")"; }

# --------------------------------------------------------- config check
CASE=canary/no-config
new_repo "$work/r1"
run_canary "$work/r1"
rc_is 0
ok; [ ! -s "$ENVF" ] || fail "no .gitleaks.toml, yet GITHUB_ENV was written: $(cat "$ENVF")"

CASE=canary/zero-rule-config
new_repo "$work/r2"
commit_file "$work/r2" .gitleaks.toml "$ZERO_RULE"
run_canary "$work/r2"
rc_is 1
has '::error file=.gitleaks.toml::gitleaks found neither of two keys' "$OUT"

CASE=canary/use-default-config
new_repo "$work/r3"
commit_file "$work/r3" .gitleaks.toml "$USE_DEFAULT"
run_canary "$work/r3"
rc_is 0
ok; grep -qxF "GITLEAKS_CONFIG=$work/r3/.gitleaks.toml" "$ENVF" || fail "GITLEAKS_CONFIG not exported to GITHUB_ENV: $(cat "$ENVF")"

# Teeth for the guard itself: the zero-rule config really does hide a leak
# from a plain scan, so the canary is what stands between it and a pass.
CASE=premise/zero-rule-hides-leak
new_repo "$work/r4"
commit_file "$work/r4" .gitleaks.toml "$ZERO_RULE"
git -C "$work/r4" update-ref refs/remotes/origin/main HEAD
commit_file "$work/r4" app.env "aws_access_key_id = \"$(fresh_key)\""
ok; (cd "$work/r4" && gitleaks git --no-banner --redact --log-opts=origin/main..HEAD . >/dev/null 2>&1) \
  || fail "gitleaks found the leak under the zero-rule config; the premise of the config check no longer holds"

# ------------------------------------------------------------------ scan
CASE=scan/pr-leak
new_repo "$work/s1"
commit_file "$work/s1" src/config.env "aws_access_key_id = \"$(fresh_key)\""
ENVF=''
run_scan "$work/s1" pull_request
rc_is 1
has '::error file=src/config.env,line=1::gitleaks: aws-access-token' "$OUT"
has 'Scanned 1 commit(s): origin/main..HEAD.' "$SUMMARY"
lacks 'AKIA' "$OUT$SUMMARY"

CASE=scan/pr-leak-removed-later
new_repo "$work/s2"
commit_file "$work/s2" leak.env "k = \"$(fresh_key)\""
git -C "$work/s2" rm -q leak.env
git -C "$work/s2" commit -q -m "remove it again"
run_scan "$work/s2" pull_request
rc_is 1
has 'Scanned 2 commit(s)' "$SUMMARY"

CASE=scan/pr-clean
new_repo "$work/s3"
commit_file "$work/s3" src/app.py 'print("hello")'
run_scan "$work/s3" pull_request
rc_is 0
has 'No leaks found.' "$SUMMARY"

CASE=scan/pr-missing-base
run_scan "$work/s3" pull_request BASE_REF=no-such-branch
rc_is 1
has 'cannot resolve the scan range origin/no-such-branch..HEAD' "$OUT"

CASE=scan/push-range
new_repo "$work/s4"
before="$(git -C "$work/s4" rev-parse HEAD)"
commit_file "$work/s4" a.env "k = \"$(fresh_key)\""
commit_file "$work/s4" b.txt 'clean'
run_scan "$work/s4" push BEFORE="$before"
rc_is 1
has "Scanned 2 commit(s): ${before}.." "$SUMMARY"

CASE=scan/push-new-branch
run_scan "$work/s4" push BEFORE=0000000000000000000000000000000000000000
rc_is 0
has 'Scanned 1 commit(s): the last commit.' "$SUMMARY"

CASE=scan/config-from-canary
# The scan loads the config the check exported: an allowlisted path is not
# reported.
new_repo "$work/s5"
commit_file "$work/s5" .gitleaks.toml "$USE_DEFAULT"
git -C "$work/s5" update-ref refs/remotes/origin/main HEAD
commit_file "$work/s5" docs/example.env "k = \"$(fresh_key)\""
run_canary "$work/s5"
rc_is 0
run_scan "$work/s5" pull_request
rc_is 0

if [ "$failures" -ne 0 ]; then
  printf 'FAIL: %s (%d of %d assertion(s) failed)\n' "$NAME" "$failures" "$checks"
  exit 1
fi
printf 'PASS: %s (%d assertion(s))\n' "$NAME" "$checks"

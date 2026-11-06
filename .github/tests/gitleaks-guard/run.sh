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
# And one way a pull request could pass with a leak in it (issue #112): the
# config and .gitleaksignore came from the PR head, so a PR could allowlist
# or ignore its own key. gitleaks also loads <source>/.gitleaks.toml when
# GITLEAKS_CONFIG is unset and <source>/.gitleaksignore always, so both must
# come from the base ref on pull_request.
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
FETCH='Fetch the push base'
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
p_i="$(pos "$INSTALL")"; p_c="$(pos "$CANARY")"; p_f="$(pos "$FETCH")"; p_s="$(pos "$SCAN")"
ok; [ -n "$p_i" ] && [ -n "$p_c" ] && [ -n "$p_f" ] && [ -n "$p_s" ] \
  && [ "$p_i" -lt "$p_c" ] && [ "$p_c" -lt "$p_f" ] && [ "$p_f" -lt "$p_s" ] \
  || fail "steps must run install < config check < fetch push base < scan (got ${p_i:-?} ${p_c:-?} ${p_f:-?} ${p_s:-?})"
ok; [ "$(yq '[.jobs.gitleaks.steps[] | select(has("if"))] | length' "$WORKFLOW")" = 0 ] \
  || fail "a gitleaks step carries an if:, so the config check or the scan can be skipped"
# The token is only for fetching a force-pushed-away push base (issue #125);
# the scan step itself holds none.
ok; [ "$(STEP="$SCAN" yq '.jobs.gitleaks.steps[] | select(.name == strenv(STEP)) | .env // {} | to_entries | map(select(.value | test("token|secrets"))) | length' "$WORKFLOW")" = 0 ] \
  || fail "'$SCAN' must not hold a token"
for s in "$INSTALL" "$CANARY" "$FETCH" "$SCAN"; do
  ok
  # shellcheck disable=SC2016 # a literal ${{, not a shell expansion
  if grep -qF '${{' <<<"$(step "$s" .run)"; then fail "'$s' interpolates an expression into its run: body"; fi
done
for k in EVENT_NAME BASE_REF; do
  ok; [ "$(K="$k" STEP="$CANARY" yq '.jobs.gitleaks.steps[] | select(.name == strenv(STEP)) | .env | has(strenv(K))' "$WORKFLOW")" = true ] \
    || fail "'$CANARY' must read $k through env:"
done
ok; grep -qF -- '--gitleaks-ignore-path "$GITLEAKS_IGNORE_PATH"' <<<"$(step "$SCAN" .run)" \
  || fail "the scan does not pass --gitleaks-ignore-path \"\$GITLEAKS_IGNORE_PATH\""
step "$CANARY" .run > "$work/canary.sh"
step "$FETCH" .run > "$work/fetch.sh"
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

# run_canary <repo> <event> [KEY=VALUE...]: sets RC, OUT (stdout), ENVF
# (GITHUB_ENV file).
run_canary() {
  local repo="$1" event="$2"
  shift 2
  rm -rf "$work/rt/c" && mkdir -p "$work/rt/c"
  ENVF="$work/rt/c/env"; : > "$ENVF"
  RC=0
  (cd "$repo" && env -u GITLEAKS_CONFIG -u GITLEAKS_IGNORE_PATH EVENT_NAME="$event" BASE_REF=main "$@" \
    RUNNER_TEMP="$work/rt/c" GITHUB_ENV="$ENVF" bash "$work/canary.sh") \
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
    unset GITLEAKS_CONFIG GITLEAKS_IGNORE_PATH
    if [ -s "${ENVF:-/dev/null}" ]; then
      while IFS='=' read -r k v; do export "$k=$v"; done < "$ENVF"
    fi
    env EVENT_NAME="$event" BASE_REF=main DEFAULT_BRANCH=main BEFORE='' AFTER="$(git rev-parse HEAD)" "$@" \
      RUNNER_TEMP="$work/rt/s" GITHUB_STEP_SUMMARY="$work/rt/s/summary.md" bash "$work/scan.sh"
  ) > "$work/rt/s/out" 2>&1 || RC=$?
  OUT="$(cat "$work/rt/s/out")"
  SUMMARY="$(cat "$work/rt/s/summary.md" 2>/dev/null || true)"
}
has()   { ok; grep -qF -- "$1" <<<"$2" || fail "expected '$1' in: $(head -c 400 <<<"$2")"; }
lacks() { ok; if grep -qF -- "$1" <<<"$2"; then fail "did not expect '$1' in output"; fi; }
rc_is() { ok; [ "$RC" = "$1" ] || fail "expected exit $1, got $RC: $(head -c 400 <<<"$OUT")"; }
# run_fetch <repo> <event> [KEY=VALUE...]: the push-base fetch step. Sets
# RC and FETCH_OUT.
run_fetch() {
  local repo="$1" event="$2"
  shift 2
  RC=0
  FETCH_OUT="$(cd "$repo" && env EVENT_NAME="$event" BEFORE='' TOKEN=fixture-token \
    SERVER_URL=https://github.com "$@" bash "$work/fetch.sh" 2>&1)" || RC=$?
}
# run_job <repo> <event> [KEY=VALUE...]: the config check, the push-base
# fetch and the scan with the same event values, as the job runs them.
run_job() {
  run_canary "$@"
  if [ "$RC" != 0 ]; then fail "the config check failed (exit $RC): $(head -c 400 <<<"$OUT")"; return; fi
  run_fetch "$@"
  if [ "$RC" != 0 ]; then fail "the push-base fetch failed (exit $RC): $(head -c 400 <<<"$FETCH_OUT")"; return; fi
  run_scan "$@"
}

# --------------------------------------------------------- config check
CASE=canary/no-config
new_repo "$work/r1"
run_canary "$work/r1" pull_request
rc_is 0
ok; grep -qxF "GITLEAKS_CONFIG=$work/rt/c/gitleaks-config/.gitleaks.toml" "$ENVF" \
  || fail "no config anywhere, yet GITLEAKS_CONFIG does not name the default-only file: $(cat "$ENVF")"
ok; grep -qxF "GITLEAKS_IGNORE_PATH=$work/rt/c/gitleaks-config/.gitleaksignore" "$ENVF" \
  || fail "GITLEAKS_IGNORE_PATH not exported: $(cat "$ENVF")"
ok; [ -f "$work/rt/c/gitleaks-config/.gitleaksignore" ] && [ ! -s "$work/rt/c/gitleaks-config/.gitleaksignore" ] \
  || fail "the ignore file for a base without one must exist and be empty"

CASE=canary/zero-rule-config-push
new_repo "$work/r2"
commit_file "$work/r2" .gitleaks.toml "$ZERO_RULE"
run_canary "$work/r2" push
rc_is 1
has '::error file=.gitleaks.toml::gitleaks found neither of two keys' "$OUT"

CASE=canary/zero-rule-config-on-base
git -C "$work/r2" update-ref refs/remotes/origin/main HEAD
commit_file "$work/r2" src/app.py 'print("hello")'
run_canary "$work/r2" pull_request
rc_is 1
has '::error::gitleaks found neither of two keys' "$OUT"
has '.gitleaks.toml from origin/main' "$OUT"

CASE=canary/use-default-config-push
new_repo "$work/r3"
commit_file "$work/r3" .gitleaks.toml "$USE_DEFAULT"
run_canary "$work/r3" push
rc_is 0
ok; grep -qxF "GITLEAKS_CONFIG=$work/r3/.gitleaks.toml" "$ENVF" || fail "GITLEAKS_CONFIG not exported to GITHUB_ENV: $(cat "$ENVF")"

CASE=canary/pr-missing-base
run_canary "$work/r3" pull_request BASE_REF=no-such-branch
rc_is 1
has '::error::gitleaks: cannot resolve the base ref origin/no-such-branch' "$OUT"

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
run_job "$work/s1" pull_request
rc_is 1
has '::error file=src/config.env,line=1::gitleaks: aws-access-token' "$OUT"
has 'Scanned 1 commit(s): origin/main..HEAD.' "$SUMMARY"
lacks 'AKIA' "$OUT$SUMMARY"

CASE=scan/pr-leak-removed-later
new_repo "$work/s2"
commit_file "$work/s2" leak.env "k = \"$(fresh_key)\""
git -C "$work/s2" rm -q leak.env
git -C "$work/s2" commit -q -m "remove it again"
run_job "$work/s2" pull_request
rc_is 1
has 'Scanned 2 commit(s)' "$SUMMARY"

CASE=scan/pr-clean
new_repo "$work/s3"
commit_file "$work/s3" src/app.py 'print("hello")'
run_job "$work/s3" pull_request
rc_is 0
has 'No leaks found.' "$SUMMARY"

CASE=scan/no-config-check
# The scan refuses to run on gitleaks' own discovery.
ENVF=''
run_scan "$work/s3" pull_request
rc_is 1
has '::error::gitleaks: GITLEAKS_CONFIG and GITLEAKS_IGNORE_PATH' "$OUT"

CASE=scan/push-range
new_repo "$work/s4"
before="$(git -C "$work/s4" rev-parse HEAD)"
commit_file "$work/s4" a.env "k = \"$(fresh_key)\""
commit_file "$work/s4" b.txt 'clean'
run_job "$work/s4" push BEFORE="$before"
rc_is 1
has "Scanned 2 commit(s): ${before}.." "$SUMMARY"

# A push that creates a branch has an all-zero before. The key sits in the
# earlier of the two commits beyond origin/main, so scanning only the last
# commit would pass it (issue #111).
CASE=scan/push-new-branch
run_job "$work/s4" push BEFORE=0000000000000000000000000000000000000000
rc_is 1
has 'Scanned 2 commit(s): origin/main..' "$SUMMARY"
has '::error file=a.env,line=1::gitleaks: aws-access-token' "$OUT"

# A force-push: before is a commit that is not an ancestor of the new head.
CASE=scan/force-push
new_repo "$work/s6"
git -C "$work/s6" switch -q -c side
commit_file "$work/s6" side.txt 'rewritten away'
replaced="$(git -C "$work/s6" rev-parse HEAD)"
git -C "$work/s6" switch -q main
commit_file "$work/s6" a.env "k = \"$(fresh_key)\""
commit_file "$work/s6" b.txt 'clean'
run_job "$work/s6" push BEFORE="$replaced"
rc_is 1
has 'Scanned 2 commit(s): origin/main..' "$SUMMARY"
has '::error file=a.env,line=1::gitleaks: aws-access-token' "$OUT"

# A force-push to the default branch itself (issue #125): origin/main is the
# new head, so there are no commits outside it. Two clean commits are
# replaced by a key commit and a clean one; scanning only the last commit
# would pass the key, so the scan covers merge-base(before, after)..after.
CASE=scan/force-push-default
new_repo "$work/f1"
fork="$(git -C "$work/f1" rev-parse HEAD)"
commit_file "$work/f1" c1.txt 'clean one'
commit_file "$work/f1" c2.txt 'clean two'
replaced="$(git -C "$work/f1" rev-parse HEAD)"
git -C "$work/f1" reset -q --hard "$fork"
commit_file "$work/f1" a.env "k = \"$(fresh_key)\""
commit_file "$work/f1" b.txt 'clean'
git -C "$work/f1" update-ref refs/remotes/origin/main HEAD
run_job "$work/f1" push BEFORE="$replaced"
rc_is 1
has '::error file=a.env,line=1::gitleaks: aws-access-token' "$OUT"
has "Scanned 2 commit(s): ${fork}..$(git -C "$work/f1" rev-parse HEAD)" "$SUMMARY"
has '::notice::gitleaks: a non-fast-forward push' "$OUT"
lacks 'earlier commits were not scanned' "$OUT$SUMMARY"

# The same push in a fresh clone: the replaced commit is reachable from no
# ref, so actions/checkout does not fetch it. The fetch step asks the remote
# for it by SHA, as GitHub serves a force-pushed-away commit.
CASE=scan/force-push-default-fetch-base
git init -q --bare "$work/f2-origin.git"
git -C "$work/f2-origin.git" config uploadpack.allowAnySHA1InWant true
git -C "$work/f1" push -q "$work/f2-origin.git" "${replaced}:refs/heads/main"
git -C "$work/f1" push -q -f "$work/f2-origin.git" HEAD:refs/heads/main
git clone -q --no-local "file://$work/f2-origin.git" "$work/f2"
ok; if git -C "$work/f2" cat-file -e "${replaced}^{commit}" 2>/dev/null; then
  fail "premise: the fresh clone already has the replaced commit, so the fetch is not exercised"
fi
run_job "$work/f2" push BEFORE="$replaced"
rc_is 1
has "fetched the push base ${replaced}" "$FETCH_OUT"
has '::error file=a.env,line=1::gitleaks: aws-access-token' "$OUT"
has "Scanned 2 commit(s): ${fork}.." "$SUMMARY"

# A push base the remote cannot serve: the fetch says so and the scan falls
# back to the last commit with its notice, as before.
CASE=scan/force-push-default-base-gone
gone=0123456789abcdef0123456789abcdef01234567
run_job "$work/f2" push BEFORE="$gone"
rc_is 0
has "::notice::gitleaks: could not fetch the push base ${gone}" "$FETCH_OUT"
has 'Scanned 1 commit(s): the last commit' "$SUMMARY"
has 'earlier commits were not scanned' "$OUT"

# The fetch step does nothing on a pull request, a fast-forward or a new
# branch, and refuses a before that is not a commit SHA.
CASE=fetch/no-op
run_fetch "$work/f2" pull_request BEFORE="$gone"
rc_is 0
ok; [ -z "$FETCH_OUT" ] || fail "the fetch step printed on a pull_request: $FETCH_OUT"
run_fetch "$work/f2" push BEFORE=0000000000000000000000000000000000000000
rc_is 0
ok; [ -z "$FETCH_OUT" ] || fail "the fetch step printed for a new branch: $FETCH_OUT"
run_fetch "$work/f2" push BEFORE="$(git -C "$work/f2" rev-parse HEAD~1)"
rc_is 0
ok; [ -z "$FETCH_OUT" ] || fail "the fetch step printed for a commit the clone has: $FETCH_OUT"
run_fetch "$work/f2" push BEFORE="--upload-pack=touch $work/pwned"
rc_is 0
has '::notice::gitleaks: the push base is not a commit SHA' "$FETCH_OUT"
ok; [ ! -e "$work/pwned" ] || fail "a before carrying an option reached git"

# schedule on the default branch: no commits outside origin/main, so the
# last commit is scanned and the summary says the earlier ones were not.
CASE=scan/schedule-on-default
new_repo "$work/s7"
commit_file "$work/s7" b.txt 'clean'
git -C "$work/s7" update-ref refs/remotes/origin/main HEAD
run_job "$work/s7" schedule
rc_is 0
has 'Scanned 1 commit(s): the last commit' "$SUMMARY"
has 'earlier commits were not scanned' "$SUMMARY"
has '::notice::gitleaks: scanned the last commit' "$OUT"
has 'earlier commits were not scanned' "$OUT"
lacks 'nothing to scan' "$OUT"

# An unresolvable default branch falls back to the last commit, with the
# same notice, rather than crashing under set -e.
CASE=scan/push-missing-default
run_job "$work/s4" push BEFORE=0000000000000000000000000000000000000000 DEFAULT_BRANCH=no-such-branch
rc_is 0
has 'Scanned 1 commit(s): the last commit' "$SUMMARY"
has 'origin/no-such-branch does not resolve' "$SUMMARY"
has 'earlier commits were not scanned' "$OUT"

CASE=scan/config-from-canary
# The scan loads the config the check exported: an allowlisted path is not
# reported.
new_repo "$work/s5"
commit_file "$work/s5" .gitleaks.toml "$USE_DEFAULT"
git -C "$work/s5" update-ref refs/remotes/origin/main HEAD
commit_file "$work/s5" docs/example.env "k = \"$(fresh_key)\""
run_job "$work/s5" pull_request
rc_is 0

# ------------------------------------------------- PR-controlled allowlist
# Issue #112: a PR that adds an allowlist or ignore entry for its own key.
ALLOW_LEAK=$'[extend]\nuseDefault = true\n\n[allowlist]\npaths = [\'\'\'^leak\\.env$\'\'\']\nregexes = [\'\'\'AKIA[A-Z2-7]{16}\'\'\']'

CASE=pr-allowlist/no-base-config
new_repo "$work/a1"
commit_file "$work/a1" .gitleaks.toml "$ALLOW_LEAK"
commit_file "$work/a1" leak.env "k = \"$(fresh_key)\""
run_job "$work/a1" pull_request
rc_is 1
has '::error file=leak.env,line=1::gitleaks: aws-access-token' "$OUT"

CASE=pr-allowlist/base-has-config
new_repo "$work/a2"
commit_file "$work/a2" .gitleaks.toml "$USE_DEFAULT"
git -C "$work/a2" update-ref refs/remotes/origin/main HEAD
commit_file "$work/a2" .gitleaks.toml "$ALLOW_LEAK"
commit_file "$work/a2" leak.env "k = \"$(fresh_key)\""
run_job "$work/a2" pull_request
rc_is 1
has '::error file=leak.env,line=1::gitleaks: aws-access-token' "$OUT"

CASE=control/allowlist-on-base-push
# The same allowlist, once on the base branch, does hide the key: a broken
# ALLOW_LEAK cannot make the two cases above pass by accident.
new_repo "$work/a3"
commit_file "$work/a3" .gitleaks.toml "$ALLOW_LEAK"
git -C "$work/a3" update-ref refs/remotes/origin/main HEAD
before="$(git -C "$work/a3" rev-parse HEAD)"
commit_file "$work/a3" leak.env "k = \"$(fresh_key)\""
run_job "$work/a3" push BEFORE="$before"
rc_is 0
has 'Scanned 1 commit(s)' "$SUMMARY"

CASE=control/allowlist-on-base-pr
run_job "$work/a3" pull_request
rc_is 0

# Issue #124: gitleaks resolves a relative [extend] path against its working
# directory, which was the PR-head checkout, so a PR could edit (or add) the
# extended file to allowlist its own key.
EXTENDS=$'[extend]\npath = "config/extra.toml"'
DEFAULT_ONLY=$'[extend]\nuseDefault = true'

CASE=pr-extend/head-edits-extended-file
new_repo "$work/e1"
commit_file "$work/e1" .gitleaks.toml "$EXTENDS"
commit_file "$work/e1" config/extra.toml "$DEFAULT_ONLY"
git -C "$work/e1" update-ref refs/remotes/origin/main HEAD
commit_file "$work/e1" config/extra.toml "$ALLOW_LEAK"
commit_file "$work/e1" leak.env "k = \"$(fresh_key)\""
run_job "$work/e1" pull_request
rc_is 1
has '::error file=leak.env,line=1::gitleaks: aws-access-token' "$OUT"

CASE=pr-extend/head-adds-extended-file
# The base extends a file it does not have; the PR supplies it.
new_repo "$work/e2"
commit_file "$work/e2" .gitleaks.toml "$EXTENDS"
git -C "$work/e2" update-ref refs/remotes/origin/main HEAD
commit_file "$work/e2" config/extra.toml "$ALLOW_LEAK"
commit_file "$work/e2" leak.env "k = \"$(fresh_key)\""
run_canary "$work/e2" pull_request
rc_is 1
has '::error file=.gitleaks.toml::gitleaks: [extend] path "config/extra.toml" names a file origin/main does not have' "$OUT"

CASE=pr-extend/nested
# A chain: .gitleaks.toml -> config/extra.toml -> config/inner.toml, each
# relative to the repository root. The PR edits the innermost file.
INNER_RULE=$'[[rules]]\nid = "aws-access-token"\nregex = \'\'\'AKIA[A-Z2-7]{16}\'\'\''
new_repo "$work/e3"
commit_file "$work/e3" .gitleaks.toml "$EXTENDS"
commit_file "$work/e3" config/extra.toml $'[extend]\npath = "config/inner.toml"'
commit_file "$work/e3" config/inner.toml "$INNER_RULE"
git -C "$work/e3" update-ref refs/remotes/origin/main HEAD
commit_file "$work/e3" config/inner.toml "$INNER_RULE"$'\n\n[allowlist]\npaths = [\'\'\'^leak\\.env$\'\'\']'
commit_file "$work/e3" leak.env "k = \"$(fresh_key)\""
run_job "$work/e3" pull_request
rc_is 1
has '::error file=leak.env,line=1::gitleaks: aws-access-token' "$OUT"

CASE=pr-extend/absolute-path
new_repo "$work/e4"
commit_file "$work/e4" .gitleaks.toml $'[extend]\npath = "/etc/gitleaks.toml"'
git -C "$work/e4" update-ref refs/remotes/origin/main HEAD
commit_file "$work/e4" src/app.py 'print("hello")'
run_canary "$work/e4" pull_request
rc_is 1
has '::error file=.gitleaks.toml::gitleaks: [extend] path "/etc/gitleaks.toml" is absolute' "$OUT"

CASE=pr-extend/escapes-repo
new_repo "$work/e5"
commit_file "$work/e5" .gitleaks.toml $'[extend]\npath = "config/../../extra.toml"'
git -C "$work/e5" update-ref refs/remotes/origin/main HEAD
commit_file "$work/e5" src/app.py 'print("hello")'
run_canary "$work/e5" pull_request
rc_is 1
has '::error file=.gitleaks.toml::gitleaks: [extend] path "config/../../extra.toml" leaves the repository' "$OUT"

CASE=control/extend-on-base
# The base's own extended allowlist applies on a pull request (it resolves
# against the base's copy) and on a push (against the checkout): a broken
# EXTENDS cannot make the cases above pass by accident.
new_repo "$work/e6"
commit_file "$work/e6" .gitleaks.toml "$EXTENDS"
commit_file "$work/e6" config/extra.toml "$ALLOW_LEAK"
git -C "$work/e6" update-ref refs/remotes/origin/main HEAD
before="$(git -C "$work/e6" rev-parse HEAD)"
commit_file "$work/e6" leak.env "k = \"$(fresh_key)\""
run_job "$work/e6" pull_request
rc_is 0
has 'No leaks found.' "$SUMMARY"
run_job "$work/e6" push BEFORE="$before"
rc_is 0
has 'Scanned 1 commit(s)' "$SUMMARY"

CASE=control/nested-on-base
# The same allowlist in the base's innermost file applies on a pull request,
# so every link of the chain is read from the base's copy.
new_repo "$work/e7"
commit_file "$work/e7" .gitleaks.toml "$EXTENDS"
commit_file "$work/e7" config/extra.toml $'[extend]\npath = "config/inner.toml"'
commit_file "$work/e7" config/inner.toml "$INNER_RULE"$'\n\n[allowlist]\npaths = [\'\'\'^leak\\.env$\'\'\']'
git -C "$work/e7" update-ref refs/remotes/origin/main HEAD
commit_file "$work/e7" leak.env "k = \"$(fresh_key)\""
run_job "$work/e7" pull_request
rc_is 0
has 'No leaks found.' "$SUMMARY"

CASE=pr-gitleaksignore
new_repo "$work/a4"
before="$(git -C "$work/a4" rev-parse HEAD)"
commit_file "$work/a4" leak.env "k = \"$(fresh_key)\""
run_job "$work/a4" pull_request
rc_is 1
fp="$(jq -r '.[0].Fingerprint // empty' "$work/rt/s/gitleaks-report.json" 2>/dev/null || true)"
ok; [ -n "$fp" ] || fail "no fingerprint in the first run's report"
commit_file "$work/a4" .gitleaksignore "$fp"
run_job "$work/a4" pull_request
rc_is 1
has '::error file=leak.env,line=1::gitleaks: aws-access-token' "$OUT"
has 'takes effect only once it is on the base branch' "$OUT"

CASE=control/gitleaksignore-push
# The fingerprint is right: after review (push) the head's entry applies.
# The PR run removed the file from its checkout; a push job gets a fresh one.
ok; [ ! -e "$work/a4/.gitleaksignore" ] || fail "the PR scan left the head's .gitleaksignore in its checkout"
git -C "$work/a4" checkout -q -- .gitleaksignore
run_job "$work/a4" push BEFORE="$before"
rc_is 0
has 'Scanned 2 commit(s)' "$SUMMARY"

if [ "$failures" -ne 0 ]; then
  printf 'FAIL: %s (%d of %d assertion(s) failed)\n' "$NAME" "$failures" "$checks"
  exit 1
fi
printf 'PASS: %s (%d assertion(s))\n' "$NAME" "$checks"

#!/usr/bin/env bash
# The single-quoted ${{ }} strings below are literal workflow expressions.
# shellcheck disable=SC2016
#
# reusable-container-release.yml's `pr-image` step waits for the PR-phase build
# to push :next-{version} and resolves that tag to a digest (issue #51). Live
# releases have shown the promote-after-wait path; they have not shown the
# branches a release only takes when the image is missing and nothing is
# building, or when the release commit's pull requests cannot be read
# (issue #62). This test runs the shipped step through every branch:
#
#   - the fast-path probe finds the image at once;
#   - nothing is in flight, so the `No in-flight ... (N run(s) inspected)`
#     notice carries a non-zero N, and a sibling workflow still running does
#     not hold the wait open;
#   - the run query returns no runs at all (the same notice, with N = 0);
#   - the release commit's pull requests are unreadable (the warning, then the
#     per-workflow counter), with nothing in flight and with a build in flight;
#   - a build is in flight and the image appears: the digest written is the
#     one the wait's own probe returned, not a later read of the tag;
#   - a build stays in flight until the bounded wait ends;
#   - a build finishes without pushing; the wait is disabled; no pull request
#     is associated; the workflow path or the run list cannot be read.
#
# It EXTRACTS the shipped `run:` body with yq and executes it under the shell
# GitHub uses for a step with no `shell:` (`bash -e {0}`), with stub `gh`,
# `docker`, `date` and `sleep` first on PATH. `date` and `sleep` share a fake
# clock, so the 600 s wait costs no real time. It never holds a retyped copy of
# the step.
#
# WORKFLOW overrides the file under test (e.g. a mutated copy, to show a case
# fails when the behaviour it pins is broken).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

NAME=container-promote-wait
WORKFLOW=${WORKFLOW:-.github/workflows/reusable-container-release.yml}
STEP_ID=pr-image
SENTINEL_GH=STUB-GH-62f0a1
SENTINEL_DOCKER=STUB-DOCKER-62f0a1
PR_IMAGE=ghcr.io/org/app:next-1.2.3
BUILD_PATH=.github/workflows/container.yml
RUN_ID=4242
RELSHA=1111111111111111111111111111111111111111
PRHEAD=2222222222222222222222222222222222222222
DA="sha256:$(printf '%064d' 0 | tr 0 a)"
DB="sha256:$(printf '%064d' 0 | tr 0 b)"
DC="sha256:$(printf '%064d' 0 | tr 0 c)"
DD="sha256:$(printf '%064d' 0 | tr 0 d)"

fatal() { echo "FATAL: $*" >&2; exit 1; }
command -v yq >/dev/null || fatal "yq is required (mikefarah/yq v4)"
command -v jq >/dev/null || fatal "jq is required (the stub gh applies --jq with it)"
command -v timeout >/dev/null || fatal "timeout is required (an unbounded wait must not hang the suite)"
[ -f "$WORKFLOW" ] || fatal "$WORKFLOW not found"

work="$(mktemp -d)" || exit 1
trap 'rm -rf "$work"' EXIT

failures=0
checks=0
CASE=contract
fail() { printf '  FAIL [%s] %s\n' "$CASE" "$1"; failures=$((failures + 1)); }
check() { checks=$((checks + 1)); }

# ---------------------------------------------------------------- extraction
Q=".jobs[].steps[] | select(.id == \"$STEP_ID\")"
[ "$(yq "[$Q] | length" "$WORKFLOW")" = 1 ] || fatal "expected exactly one step with id '$STEP_ID' in $WORKFLOW"
yq -r "$Q | .run" "$WORKFLOW" > "$work/step.sh"
[ -s "$work/step.sh" ] || fatal "no run body extracted for step '$STEP_ID'"
if [ "$(yq "$Q | .shell // \"\"" "$WORKFLOW")" != "" ] ||
   [ "$(yq '[.. | select(tag == "!!map" and has("defaults"))] | length' "$WORKFLOW")" != 0 ]; then
  fatal "step '$STEP_ID' now runs under a configured shell; update the interpreter this harness uses"
fi
WAIT_DEFAULT=$(yq -r '.on.workflow_call.inputs.promote-wait-seconds.default' "$WORKFLOW")
case "$WAIT_DEFAULT" in '' | *[!0-9]* | 0) fatal "promote-wait-seconds default is not a positive integer: '$WAIT_DEFAULT'" ;; esac

check
grep -qF '${{' "$work/step.sh" && fail "run body interpolates \${{ }} expressions; read them through env: instead"

# The harness sets exactly the variables the step's env: map provides, each
# bound to the expression it stands in for. A variable the step stopped
# receiving, or a new one the harness does not set, fails here.
EXPECTED_ENV='BUILD_WORKFLOW=${{ inputs.build-workflow }}
GH_TOKEN=${{ secrets.GITHUB_TOKEN }}
IMAGE_NAME=${{ inputs.image-name }}
PR_IMAGE=${{ steps.version.outputs.next_image }}
RELEASE_SHA=${{ github.sha }}
REPO=${{ github.repository }}
RUN_ID=${{ github.run_id }}
WAIT_CEILING=${{ inputs.promote-wait-seconds }}'
check
actual_env=$(yq -r "$Q | .env | to_entries | .[] | .key + \"=\" + .value" "$WORKFLOW" | LC_ALL=C sort)
[ "$actual_env" = "$EXPECTED_ENV" ] ||
  fail "step env differs from the harness's; got: $(tr '\n' ' ' <<< "$actual_env")"

# ---------------------------------------------------------------- stubs
mkdir -p "$work/bin"
# next_line KEY: the next scripted line for KEY (the last line repeats). An
# unscripted KEY means the step made a call this case did not expect.
cat > "$work/bin/_seq" <<'STUB'
#!/usr/bin/env bash
seq="$STUB_DIR/$1.seq"
[ -s "$seq" ] || { echo "UNSCRIPTED"; exit 0; }
cnt="$STUB_DIR/$1.count"
n=$(( $(cat "$cnt" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$cnt"
total=$(wc -l < "$seq"); [ "$n" -le "$total" ] || n=$total
sed -n "${n}p" "$seq"
STUB
cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Stub gh: answers only the four `gh api` reads the pr-image step makes, from
# $STUB_DIR/<key>.seq (a JSON payload or `error` per call). --jq goes through
# real jq, so the step's own filters are exercised.
echo "STUB-GH-62f0a1 $*" >> "$STUB_DIR/calls.log"
[ "${1:-}" = api ] || { echo "stub gh: unexpected call: $*" >&2; exit 97; }
path=$2; shift 2
expr=""
while [ $# -gt 0 ]; do
  case "$1" in
    --jq | -q) expr=$2; shift 2 ;;
    *) echo "stub gh: unexpected argument $1" >&2; exit 96 ;;
  esac
done
case "$path" in
  repos/org/app/actions/runs/4242) key=runpath ;;
  repos/org/app/commits/*/pulls) key=pulls ;;
  'repos/org/app/actions/runs?head_sha='*'&per_page=50') key=runs ;;
  'repos/org/app/actions/workflows/container.yml/runs?event=pull_request&per_page=50') key=wfruns ;;
  *) echo "stub gh: unexpected api path $path" >&2; exit 97 ;;
esac
line=$(_seq "$key")
case "$line" in
  UNSCRIPTED) echo "stub gh: no scripted answer for $key" >&2; exit 95 ;;
  error) echo "HTTP 403: Resource not accessible by integration (stub)" >&2; exit 1 ;;
esac
if [ -n "$expr" ]; then jq -r "$expr" <<< "$line"; else printf '%s\n' "$line"; fi
STUB
cat > "$work/bin/docker" <<'STUB'
#!/usr/bin/env bash
# Stub docker: only `docker buildx imagetools inspect ghcr.io/org/app:next-1.2.3`.
# Each call takes the next line of $STUB_DIR/probe.seq: `fail`, or
# `ok:<digest>`, printed in imagetools' text layout for an OCI index.
echo "STUB-DOCKER-62f0a1 $*" >> "$STUB_DIR/calls.log"
if [ "$#" -ne 4 ] || [ "$1 $2 $3" != "buildx imagetools inspect" ] || [ "$4" != ghcr.io/org/app:next-1.2.3 ]; then
  echo "stub docker: unexpected call: $*" >&2; exit 97
fi
line=$(_seq probe)
case "$line" in
  ok:*)
    d=${line#ok:}
    printf 'Name:      %s\nMediaType: application/vnd.oci.image.index.v1+json\nDigest:    %s\n\nManifests:\n  Name:        %s@%s\n  MediaType:   application/vnd.oci.image.manifest.v1+json\n  Platform:    linux/amd64\n' \
      "$4" "$d" "$4" "$(printf '%064d' 0 | tr 0 e)"
    ;;
  fail) echo "ERROR: $4: not found (stub)" >&2; exit 1 ;;
  *) echo "stub docker: no scripted answer" >&2; exit 95 ;;
esac
STUB
cat > "$work/bin/date" <<'STUB'
#!/usr/bin/env bash
# Stub date: the fake clock in $STUB_DIR/clock. Only `date +%s` is served.
[ "$*" = "+%s" ] || { echo "stub date: unexpected arguments: $*" >&2; exit 97; }
echo "STUB-DATE" >> "$STUB_DIR/calls.log"
cat "$STUB_DIR/clock"
STUB
cat > "$work/bin/sleep" <<'STUB'
#!/usr/bin/env bash
# Stub sleep: advances the fake clock instead of waiting.
case "${1:-}" in '' | *[!0-9]*) echo "stub sleep: unexpected argument '$*'" >&2; exit 97 ;; esac
echo "STUB-SLEEP $1" >> "$STUB_DIR/calls.log"
echo $(( $(cat "$STUB_DIR/clock") + $1 )) > "$STUB_DIR/clock"
STUB
chmod +x "$work/bin/_seq" "$work/bin/gh" "$work/bin/docker" "$work/bin/date" "$work/bin/sleep"
for t in gh docker date sleep; do
  [ -x "$work/bin/$t" ] || fatal "stub $t is not executable"
  [ "$(PATH="$work/bin:$PATH" command -v "$t")" = "$work/bin/$t" ] || fatal "stub $t is not first on PATH"
done

# ---------------------------------------------------------------- fixtures
pulls_json() { jq -cn '$ARGS.positional | map({head: {sha: .}})' --args "$@"; }
# runs_json PATH:STATUS ... -> a /actions/runs payload.
runs_json() {
  jq -cn '$ARGS.positional | map(split(":") | {path: .[0], status: .[1]})
          | {total_count: length, workflow_runs: .}' --args "$@"
}
RUNPATH_JSON=$(jq -cn --arg p "$BUILD_PATH" '{id: 4242, path: $p}')
INFLIGHT=$(runs_json "$BUILD_PATH:in_progress" .github/workflows/tests.yml:completed)
FINISHED=$(runs_json "$BUILD_PATH:completed" .github/workflows/tests.yml:completed)

# ---------------------------------------------------------------- runner
# Set P_PROBE, P_RUNPATH, P_PULLS, P_RUNS, P_WFRUNS (|-separated sequences,
# empty = the call is not expected), then: run_case NAME [VAR=VALUE ...]
reset_fixtures() {
  P_PROBE="" P_RUNPATH="$RUNPATH_JSON" P_PULLS="$(pulls_json "$PRHEAD")" P_RUNS="" P_WFRUNS=""
}
run_case() {
  CASE=$1; shift
  local dir="$work/case-$CASE"
  mkdir -p "$dir/cwd"
  local k v
  for k in probe runpath pulls runs wfruns; do
    case $k in
      probe) v=$P_PROBE ;; runpath) v=$P_RUNPATH ;; pulls) v=$P_PULLS ;;
      runs) v=$P_RUNS ;; wfruns) v=$P_WFRUNS ;;
    esac
    if [ -n "$v" ]; then tr '|' '\n' <<< "$v" > "$dir/$k.seq"; else : > "$dir/$k.seq"; fi
  done
  echo 1000000 > "$dir/clock"
  : > "$dir/calls.log"
  : > "$dir/output"
  set +e
  (cd "$dir/cwd" && env -i PATH="$work/bin:$PATH" HOME="$dir" STUB_DIR="$dir" \
    GITHUB_OUTPUT="$dir/output" GH_TOKEN=stub-token REPO=org/app RUN_ID="$RUN_ID" \
    RELEASE_SHA="$RELSHA" PR_IMAGE="$PR_IMAGE" IMAGE_NAME=org/app \
    WAIT_CEILING="$WAIT_DEFAULT" BUILD_WORKFLOW="" \
    "$@" timeout 60 bash -e "$work/step.sh") > "$dir/out" 2>&1
  RC=$?
  set -e
  LOG="$dir/calls.log"
  OUT="$dir/out"
  GOUT="$dir/output"
}
ctx() { echo "(rc $RC; output: $(tr '\n' ' ' < "$OUT"))"; }
n_docker() { grep -c "^$SENTINEL_DOCKER " "$LOG" || true; }
n_gh() { grep -c "^$SENTINEL_GH api $1" "$LOG" || true; }
sleeps() { { grep '^STUB-SLEEP ' "$LOG" || true; } | awk '{print $2}' | paste -sd' ' -; }
outv() { { grep "^$1=" "$GOUT" || true; } | tail -n 1 | cut -d= -f2-; }
expect_rc0() { check; [ "$RC" = 0 ] || fail "rc $RC, expected 0 $(ctx)"; }
expect_outv() { check; [ "$(outv "$1")" = "$2" ] || fail "GITHUB_OUTPUT $1='$(outv "$1")', expected '$2' $(ctx)"; }
expect_no_outv() { check; grep -q "^$1=" "$GOUT" && fail "GITHUB_OUTPUT has $1 on this path: $(tr '\n' ' ' < "$GOUT")"; return 0; }
# Every output the step writes is written exactly once (emit ran once, then exit).
expect_emitted_once() {
  local k
  for k in exists image waited wait_gate; do
    check
    [ "$(grep -c "^$k=" "$GOUT" || true)" = 1 ] || fail "$k written $(grep -c "^$k=" "$GOUT" || true) time(s), expected 1: $(tr '\n' ' ' < "$GOUT")"
  done
}
expect_found() { # DIGEST GATE WAITED
  expect_rc0
  expect_emitted_once
  expect_outv exists true
  expect_outv digest "$1"
  expect_outv image "ghcr.io/org/app@$1"
  expect_outv wait_gate "$2"
  expect_outv waited "$3"
}
expect_not_found() { # GATE WAITED
  expect_rc0
  expect_emitted_once
  expect_outv exists false
  expect_no_outv digest
  expect_outv image "$PR_IMAGE"
  expect_outv wait_gate "$1"
  expect_outv waited "$2"
}
expect_out() { check; grep -qF -- "$1" "$OUT" || fail "output lacks '$1' $(ctx)"; }
expect_no_out() { check; grep -qF -- "$1" "$OUT" && fail "output contains '$1' $(ctx)"; return 0; }
expect_docker() {
  check
  [ "$(n_docker)" = "$1" ] || fail "docker inspect called $(n_docker) time(s), expected $1 $(ctx)"
}
expect_gh() { check; [ "$(n_gh "$1")" = "$2" ] || fail "gh api $1 called $(n_gh "$1") time(s), expected $2"; }
expect_sleeps() { check; [ "$(sleeps)" = "$1" ] || fail "sleeps '$(sleeps)', expected '$1'"; }
expect_stubs() { # the stubs, not the real tools, answered
  check
  grep -q "^$SENTINEL_DOCKER " "$LOG" || fail "stub docker sentinel never logged; the real docker may have run"
  check
  grep -q '^STUB-DATE$' "$LOG" || fail "stub date sentinel never logged; the real clock was read"
  if [ "${1:-}" = gh ]; then
    check
    grep -q "^$SENTINEL_GH " "$LOG" || fail "stub gh sentinel never logged; the real gh may have run"
  fi
}
repeat() { local i out=""; for ((i = 0; i < $1; i++)); do out+="$2 "; done; echo "${out% }"; }
NOTICE_PREFIX="::notice::No in-flight $BUILD_PATH run for this release"
PULLS_WARNING="::warning::Could not read the release commit's pull requests"
URL_RUNS="repos/org/app/actions/runs?head_sha="
URL_WF="repos/org/app/actions/workflows/container.yml/runs?event=pull_request&per_page=50"

# ================================================================ cases
# 1. Fast path: the image is already in GHCR. No API call, no wait.
reset_fixtures
P_PROBE="ok:$DA|ok:$DB"
run_case fast-path
expect_found "$DA" not-needed 0
expect_stubs
expect_docker 1
check; grep -q "^$SENTINEL_GH " "$LOG" && fail "gh was called on the fast path"
expect_sleeps ""
expect_out "PR image found at $DA"

# 2. Nothing in flight (the branch issue #62 could not observe live): the
#    query returned three runs, none of them an unfinished container build.
#    Sibling workflows still running must not hold the wait open, and the
#    notice reports the non-zero count, which is the control that the query ran.
reset_fixtures
P_PROBE=fail
P_RUNS=$(runs_json "$BUILD_PATH:completed" .github/workflows/security.yml:in_progress .github/workflows/tests.yml:queued)
run_case nothing-in-flight
expect_not_found nothing-in-flight 6
expect_stubs gh
expect_out "$NOTICE_PREFIX (3 run(s) inspected) — rebuilding now rather than waiting."
expect_no_out "Waiting up to"
expect_no_out "::warning::"
expect_gh repos/org/app/actions/runs/4242 1
expect_gh "repos/org/app/commits/$RELSHA/pulls" 1
# Keyed on the release PR's head commit, never on the release commit.
expect_gh "${URL_RUNS}${PRHEAD}&per_page=50" 1
expect_gh "${URL_RUNS}${RELSHA}" 0
expect_gh "$URL_WF" 0
# Fast-path probe, then the three settled probes before conceding.
expect_docker 4
expect_sleeps "3 3"

# 2b. Same branch, but the image lands during the closing re-probe: promote.
reset_fixtures
P_PROBE="fail|fail|ok:$DB|ok:$DD"
P_RUNS=$(runs_json "$BUILD_PATH:completed")
run_case nothing-in-flight-late-image
expect_found "$DB" nothing-in-flight 3
expect_out "$NOTICE_PREFIX (1 run(s) inspected)"
expect_docker 3
expect_sleeps "3"

# 3. The run query returned no runs at all: the same notice, with a zero
#    count. This is what tells an inert query apart from a genuine zero.
reset_fixtures
P_PROBE=fail
P_RUNS='{"total_count":0,"workflow_runs":[]}'
run_case no-runs-at-all
expect_not_found nothing-in-flight 6
expect_stubs gh
expect_out "$NOTICE_PREFIX (0 run(s) inspected) — rebuilding now rather than waiting."
expect_gh "${URL_RUNS}${PRHEAD}&per_page=50" 1

# 4. The release commit's pull requests are unreadable (a caller whose job
#    grants no `pull-requests` scope): warn, then count by workflow instead.
reset_fixtures
P_PROBE=fail
P_PULLS=error
P_WFRUNS=$(runs_json "$BUILD_PATH:completed" "$BUILD_PATH:completed")
run_case pulls-unreadable-nothing-in-flight
expect_not_found nothing-in-flight 6
expect_stubs gh
expect_out "$PULLS_WARNING"
expect_out "$NOTICE_PREFIX (2 run(s) inspected)"
expect_gh "$URL_WF" 1
expect_gh "$URL_RUNS" 0
check
w=$({ grep -nF -- "$PULLS_WARNING" "$OUT" || true; } | cut -d: -f1 | head -n 1)
n=$({ grep -nF -- "$NOTICE_PREFIX" "$OUT" || true; } | cut -d: -f1 | head -n 1)
[ -n "$w" ] && [ -n "$n" ] && [ "$w" -lt "$n" ] || fail "the pull-requests warning does not precede the notice $(ctx)"

# 4b. Fallback with a build in flight, and build-workflow set explicitly (so
#     the caller's run path is never looked up): the wait still promotes.
reset_fixtures
P_PROBE="fail|fail|ok:$DC|ok:$DD"
P_PULLS=error
P_WFRUNS=$(runs_json "$BUILD_PATH:in_progress")
run_case pulls-unreadable-in-flight BUILD_WORKFLOW="$BUILD_PATH"
expect_found "$DC" waited 20
expect_stubs gh
expect_out "$PULLS_WARNING"
expect_out "PR image not in GHCR yet; 1 $BUILD_PATH run(s) still in flight."
expect_gh repos/org/app/actions/runs/4242 0
expect_gh "$URL_WF" 2
expect_gh "$URL_RUNS" 0

# 5. A build is in flight and the image appears on the second poll. The
#    digest is the one that probe returned ($DC); the stub would answer $DD to
#    any later read of the tag, so a re-read would show up here.
reset_fixtures
P_PROBE="fail|fail|ok:$DC|ok:$DD"
P_RUNS="$INFLIGHT|$INFLIGHT"
run_case in-flight-then-image
expect_found "$DC" waited 20
expect_stubs gh
expect_out "PR image not in GHCR yet; 1 $BUILD_PATH run(s) still in flight. Waiting up to ${WAIT_DEFAULT}s for $PR_IMAGE"
expect_out "PR image appeared at $DC after 20s"
expect_docker 3
expect_sleeps "10 10"
expect_gh "${URL_RUNS}${PRHEAD}&per_page=50" 2
expect_no_out "::warning::"

# 6. A build stays in flight and the image never appears: the wait stops at
#    the ceiling (the input's shipped default) and the job rebuilds.
reset_fixtures
P_PROBE=fail
P_RUNS=$INFLIGHT
run_case in-flight-until-ceiling
polls=$(( WAIT_DEFAULT / 10 ))
expect_not_found waited "$WAIT_DEFAULT"
expect_stubs gh
expect_out "::warning::Pre-built PR image $PR_IMAGE did not appear after ${WAIT_DEFAULT}s — falling back to full rebuild"
expect_sleeps "$(repeat "$polls" 10)"
expect_docker $(( polls + 1 ))
expect_gh "${URL_RUNS}${PRHEAD}&per_page=50" $(( polls + 1 ))

# 7. The build finishes without the image appearing: stop early, re-probe,
#    and rebuild rather than spend the rest of the ceiling.
reset_fixtures
P_PROBE=fail
P_RUNS="$INFLIGHT|$FINISHED"
run_case build-finished-without-image
expect_not_found waited 16
expect_out "No $BUILD_PATH run left in flight after 10s"
expect_out "::warning::Pre-built PR image $PR_IMAGE did not appear after 16s"
expect_sleeps "10 3 3"
expect_docker 5

# 8. promote-wait-seconds 0: one probe, then rebuild; no API call.
reset_fixtures
P_PROBE=fail
run_case wait-disabled WAIT_CEILING=0
expect_not_found disabled 0
expect_out "promote-wait-seconds is 0"
expect_docker 1
check; grep -q "^$SENTINEL_GH " "$LOG" && fail "gh was called with the wait disabled"
expect_sleeps ""

# 9. No pull request is associated with the release commit.
reset_fixtures
P_PROBE=fail
P_PULLS='[]'
run_case no-pr
expect_not_found no-pr 6
expect_out "::notice::No pull request is associated with $RELSHA"
expect_gh "$URL_RUNS" 0
expect_gh "$URL_WF" 0

# 10. The run list is unreadable: warn, and the gate says so.
reset_fixtures
P_PROBE=fail
P_RUNS=error
run_case runs-unreadable
expect_not_found unavailable 6
expect_out "::warning::Could not read workflow runs"
expect_no_out "$NOTICE_PREFIX"

# 11. The caller's workflow path is unreadable and build-workflow is unset.
reset_fixtures
P_PROBE=fail
P_RUNPATH=error
run_case run-path-unreadable
expect_not_found unavailable 6
expect_out "::warning::Could not resolve the PR-phase build workflow path"
expect_gh "repos/org/app/commits/" 0

if [ "$failures" -gt 0 ]; then
  echo "FAIL: $NAME ($failures of $checks assertion(s) failed)"
  exit 1
fi
echo "PASS: $NAME ($checks assertion(s))"

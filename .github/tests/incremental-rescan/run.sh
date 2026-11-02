#!/usr/bin/env bash
# Test for the incremental re-scan in the analysis workflows.
#
# Every push to an open PR used to send every matched file in the whole PR to
# the model again. On a synchronize event whose previous head was analysed
# clean, `Get changed files` now keeps only the PR files the push changed, and
# a push that changed none of them skips the analysis. Measured over 30 days
# on comfyui-nodes, mcu-tinkering-lab and pal-mcp-server, 71 of 188 repeat
# runs would have skipped and files sent fell from 1283 to 270. Two traps the
# design avoids, both pinned here:
#
#   - a push that merges the base into the branch changes files that are not
#     the PR's, so the push's own range (BEFORE..AFTER) alone is wider than
#     the PR; it is intersected with the PR's files;
#   - "the previous run succeeded" does not mean it analysed anything (the
#     diff-size and no-match skips are green too), so the proof is a cache
#     marker that `Check whether this scan was clean` writes only after a
#     complete, finding-free analysis.
#
# For every step binding FILE_PATTERNS it checks the wiring with yq, then
# EXTRACTS the shipped file-list and clean-check bodies and runs them on
# scratch repositories and fixture payloads.
#
# Usage: bash .github/tests/incremental-rescan/run.sh
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

NAME=incremental-rescan
command -v yq >/dev/null || { echo "FATAL: yq (mikefarah) is required" >&2; exit 1; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0
checks=0
CASE=setup
fail() { printf '  FAIL [%s] %s\n' "$CASE" "$1"; failures=$((failures + 1)); }
ok()   { checks=$((checks + 1)); }
eq()   { ok; [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"; }

export GIT_CONFIG_GLOBAL="$work/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --file "$GIT_CONFIG_GLOBAL" user.name fixture
git config --file "$GIT_CONFIG_GLOBAL" user.email fixture@example.invalid
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
git config --file "$GIT_CONFIG_GLOBAL" core.hooksPath /dev/null

g() { git -C "$repo" "$@"; }
edit() { mkdir -p "$repo/$(dirname "$1")"; printf '%s\n' "$2" >> "$repo/$1"; g add -A; g commit -q -m "edit $1"; }

# One repository for every case: main has README.md; the PR branch adds
# src/a.py and src/b.py (head B0, scanned clean). Later heads:
#   B1  edits src/a.py                      (fast-forward of B0)
#   B2  merges main after main added lib/c.py and edited README.md
#   F1  rewrites the branch from main (a force-push; B0 is not an ancestor)
repo="$work/repo"
git init -q "$repo"
edit README.md base
g switch -q -c pr
edit src/a.py a
edit src/b.py b
B0="$(g rev-parse HEAD)"
edit src/a.py a2
B1="$(g rev-parse HEAD)"
g switch -q main
edit lib/c.py c
edit README.md more
MAIN2="$(g rev-parse HEAD)"
g switch -q pr
g merge -q --no-edit main
B2="$(g rev-parse HEAD)"
g switch -q -c rewritten "$MAIN2"
edit src/a.py fresh
F1="$(g rev-parse HEAD)"
g update-ref refs/remotes/origin/main "$MAIN2"

# run_changed <head> <prior-hit> <before> <patterns>
run_changed() {
  g checkout -q --detach "$1"
  rm -rf "$work/run" && mkdir -p "$work/run"
  : > "$work/run/out"
  local rc=0
  (
    cd "$repo"
    while IFS=$'\t' read -r k v; do [ -n "$k" ] && export "$k=$v"; done < "$work/literal-env"
    PRIOR_CLEAN="$2" BEFORE="$3" AFTER="$1" EVENT_NAME=pull_request BASE_REF=main \
      FILE_PATTERNS="$4" FILE_LIMIT=50 MAX_DIFF_LINES=0 \
      GITHUB_OUTPUT="$work/run/out" GITHUB_STEP_SUMMARY="$work/run/summary" bash "$work/changed.sh"
  ) > "$work/run/stdout" 2>&1 || rc=$?
  ok; [ "$rc" = 0 ] || fail "file-list step exited $rc: $(head -c 300 "$work/run/stdout")"
  FILES="$(awk '/^files<<EOF$/ { f = 1; next } /^EOF$/ { f = 0 } f' "$work/run/out" | sed '/^$/d' | tr '\n' ' ')"
  COUNT="$(sed -n 's/^count=//p' "$work/run/out")"
  UNCHANGED="$(sed -n 's/^unchanged=//p' "$work/run/out")"
  NARROWED="$(sed -n 's/^narrowed=//p' "$work/run/out")"
}

# run_clean <payload json or ''> <analyze outcome> <degraded> <truncated> <unchanged>
run_clean() {
  rm -rf "$work/rt" && mkdir -p "$work/rt"
  if [ -n "$1" ]; then printf '%s\n' "$1" > "$work/rt/publish-findings-input.json"; fi
  : > "$work/rt/out"
  local rc=0
  ANALYZE_OUTCOME="$2" DEGRADED="$3" TRUNCATED="$4" UNCHANGED="$5" RUNNER_TEMP="$work/rt" \
    GITHUB_SHA=abc123 GITHUB_OUTPUT="$work/rt/out" bash "$work/clean.sh" > "$work/rt/stdout" 2>&1 || rc=$?
  ok; [ "$rc" = 0 ] || fail "clean-check step exited $rc: $(head -c 300 "$work/rt/stdout")"
  CLEAN="$(sed -n 's/^clean=//p' "$work/rt/out")"
  MARKER=no
  if [ -s "$work/rt/analysis-clean-marker/scanned" ]; then MARKER=yes; fi
}

found=0
for WF in .github/workflows/reusable-*.yml .github/workflows/reusable-*.yaml; do
  [ -f "$WF" ] || continue
  [ "$(yq '[.jobs.*.steps[] | select(.env.FILE_PATTERNS != null)] | length' "$WF")" -gt 0 ] || continue
  found=$((found + 1))
  W="$(basename "$WF" .yml)"
  sel() { ID="$1" yq "[.jobs.*.steps[] | select(.id == strenv(ID))] | .[0] | $2 // \"\"" "$WF"; }

  # ---------------------------------------------------------------- wiring
  CASE="$W/wiring"
  # shellcheck disable=SC2016 # literal ${{ }} expressions throughout
  {
    eq "$(sel prior .uses | cut -d@ -f1)" actions/cache/restore "lookup step action"
    ok; sel prior .uses | grep -qE '@[0-9a-f]{40}$' || fail "actions/cache/restore is not SHA-pinned"
    eq "$(sel prior '.with.lookup-only')" true "lookup-only"
    eq "$(sel prior .with.key)" '${{ steps.scankey.outputs.prefix }}-${{ github.event.before }}' "lookup key"
    ok; case "$(sel prior .if)" in *"github.event.action == 'synchronize'"*) ;; *) fail "the lookup does not require a synchronize event" ;; esac
    eq "$(sel changed .env.PRIOR_CLEAN)" '${{ steps.prior.outputs.cache-hit }}' "file list PRIOR_CLEAN"
    eq "$(sel changed .env.BEFORE)" '${{ github.event.before }}' "file list BEFORE"
    eq "$(sel changed .env.AFTER)" '${{ github.event.pull_request.head.sha }}' "file list AFTER"
    eq "$(sel scankey .env.INPUTS_JSON)" '${{ toJSON(inputs) }}' "marker key covers every input"
    ok; [ -n "$(sel scankey .env.SCAN)" ] || fail "the marker key names no scan"
  }
  # The marker is written last in the job, so a failing step or gate above
  # (default success()) leaves none.
  last2="$(yq -r '[.jobs | to_entries | .[0].value.steps[] | .name] | .[-2:] | join("|")' "$WF")"
  eq "$last2" "Check whether this scan was clean|Record a clean scan" "last two steps of the scan job"
  eq "$(yq '[.jobs | to_entries | .[0].value.steps[] | select(.name == "Record a clean scan")] | .[0].if' "$WF")" \
    "steps.clean.outputs.clean == 'true'" "save step if:"
  # shellcheck disable=SC2016
  eq "$(yq '[.jobs | to_entries | .[0].value.steps[] | select(.name == "Record a clean scan")] | .[0].with.key' "$WF")" \
    '${{ steps.scankey.outputs.prefix }}-${{ github.event.pull_request.head.sha }}' "save key"
  ok
  case "$(sel clean .if)" in *"always()"* | *"failure()"* | *"cancelled()"*) fail "the clean check overrides success(): $(sel clean .if)" ;; esac
  # shellcheck disable=SC2016
  eq "$(yq '[.jobs.*.steps[] | select(.name == "Report that nothing was scanned")] | .[0].env.UNCHANGED_SINCE_CLEAN' "$WF")" \
    '${{ steps.changed.outputs.unchanged }}' "report binds UNCHANGED_SINCE_CLEAN"

  sel changed .run > "$work/changed.sh"
  sel clean .run > "$work/clean.sh"
  # shellcheck disable=SC2016
  yq -r '[.jobs.*.steps[] | select(.id == "changed")] | .[0].env | to_entries | .[]
         | select((.value | tostring) | test("\$\{\{") | not) | .key + "\t" + (.value | tostring)' "$WF" > "$work/literal-env"

  # ------------------------------------------------------------- file list
  P='**/*.py **/*.md'
  CASE="$W/push-edits-one-pr-file"
  run_changed "$B1" true "$B0" "$P"
  eq "$FILES" "src/a.py " "files"; eq "$COUNT" 1 "count"; eq "$NARROWED" true "narrowed"; eq "$UNCHANGED" false "unchanged"
  ok; grep -q 're-scanning the 1 of 2 PR file(s) this push changed' "$work/run/stdout" || fail "no narrowing notice"

  CASE="$W/merge-from-base-adds-nothing"
  run_changed "$B2" true "$B1" "$P"
  eq "$COUNT" 0 "count"; eq "$UNCHANGED" true "unchanged"

  CASE="$W/no-marker-scans-whole-pr"
  run_changed "$B1" '' "$B0" "$P"
  eq "$FILES" "src/a.py src/b.py " "files"; eq "$NARROWED" false "narrowed"

  CASE="$W/force-push-scans-whole-pr"
  run_changed "$F1" true "$B1" "$P"
  eq "$FILES" "src/a.py " "files (the rewritten PR's own files)"; eq "$NARROWED" false "narrowed"

  CASE="$W/unknown-before-scans-whole-pr"
  run_changed "$B1" true 0123456789abcdef0123456789abcdef01234567 "$P"
  eq "$FILES" "src/a.py src/b.py " "files"; eq "$NARROWED" false "narrowed"

  # ----------------------------------------------------------- clean check
  CLEAN_PAYLOAD='{"secrets_count": 0, "total_issues": 0, "findings": []}'
  CASE="$W/clean/complete-and-empty";  run_clean "$CLEAN_PAYLOAD" success false false false; eq "$CLEAN" true clean; eq "$MARKER" yes marker
  CASE="$W/clean/has-finding";         run_clean '{"total_issues": 1, "findings": [{"file": "a.py", "severity": "Low", "description": "x"}]}' success false false false; eq "$CLEAN" false clean; eq "$MARKER" no marker
  CASE="$W/clean/count-without-item";  run_clean '{"total_issues": 2, "findings": []}' success false false false; eq "$CLEAN" false clean
  CASE="$W/clean/truncated";           run_clean "$CLEAN_PAYLOAD" success false true false; eq "$CLEAN" false clean
  CASE="$W/clean/degraded-unset";      run_clean "$CLEAN_PAYLOAD" success '' false false; eq "$CLEAN" false clean
  CASE="$W/clean/analysis-failed";     run_clean "$CLEAN_PAYLOAD" failure false false false; eq "$CLEAN" false clean
  CASE="$W/clean/analysis-skipped";    run_clean '' skipped '' false false; eq "$CLEAN" false clean
  CASE="$W/clean/no-payload";          run_clean '' success false false false; eq "$CLEAN" false clean
  CASE="$W/clean/unchanged";           run_clean '' skipped '' '' true; eq "$CLEAN" true clean; eq "$MARKER" yes marker
done

CASE=scan
ok; [ "$found" -gt 0 ] || fail "no reusable workflow step binds FILE_PATTERNS; the scan checked nothing"

if [ "$failures" -ne 0 ]; then
  printf 'FAIL: %s (%d of %d assertion(s) failed across %d workflow(s))\n' "$NAME" "$failures" "$checks" "$found"
  exit 1
fi
printf 'PASS: %s (%d assertion(s) across %d workflow(s))\n' "$NAME" "$checks" "$found"

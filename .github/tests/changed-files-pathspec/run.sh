#!/usr/bin/env bash
# Regression test: the analysis workflows' file list must include files at
# the repository root.
#
# Each analysis workflow lists the files to scan with
# `git diff --name-only "$RANGE" -- $FILE_PATTERNS`. Without glob magic a git
# pathspec `*` matches across `/`, but the literal `/` in `**/` still has to
# match, so every `**/<x>` pattern (every default here, and the secrets scan's
# `**/*`) dropped root-level files: `.env.example`, `.mcp.json`,
# `docker-compose.yml`, a top-level `server.py`. A PR that changed only root
# files got the green "nothing was scanned" notice. GIT_GLOB_PATHSPECS=1 makes
# `**/` match zero or more directories.
#
# For every step in a reusable workflow that binds FILE_PATTERNS, this test
# EXTRACTS the shipped run: body and its literal env values with yq and runs
# them in a scratch repository whose PR commit adds one root-level and one
# nested file per pattern.
#
# Usage: bash .github/tests/changed-files-pathspec/run.sh
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

NAME=changed-files-pathspec
command -v yq >/dev/null || { echo "FATAL: yq (mikefarah) is required" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0
checks=0
fail() { printf '  FAIL [%s] %s\n' "$CASE" "$1"; failures=$((failures + 1)); }
ok()   { checks=$((checks + 1)); }

# Isolated git: a developer's global hooks or config must not run here.
export GIT_CONFIG_GLOBAL="$work/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --file "$GIT_CONFIG_GLOBAL" user.name fixture
git config --file "$GIT_CONFIG_GLOBAL" user.email fixture@example.invalid
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
git config --file "$GIT_CONFIG_GLOBAL" core.hooksPath /dev/null

# make_repo <dir> <path...>: a base commit on origin/main, then a PR commit
# that adds every <path>.
make_repo() {
  local dir="$1" p
  shift
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m base
  git -C "$dir" update-ref refs/remotes/origin/main HEAD
  for p in "$@"; do
    mkdir -p "$dir/$(dirname "$p")"
    printf 'x\n' > "$dir/$p"
  done
  git -C "$dir" add -A
  git -C "$dir" commit -q -m pr
}

# run_step <repo> <patterns>: run the extracted body in <repo> as a
# pull_request against main; sets OUT to its GITHUB_OUTPUT file.
run_step() {
  local repo="$1" patterns="$2"
  rm -rf "$work/run"
  mkdir -p "$work/run"
  OUT="$work/run/output"
  : > "$OUT"
  set +e
  (
    cd "$repo"
    # Literal env values (GIT_GLOB_PATHSPECS among them) are exported as
    # shipped; the ${{ }} bindings are set below as GitHub would.
    while IFS=$'\t' read -r key value; do
      [ -n "$key" ] && export "$key=$value"
    done < "$work/literal-env"
    EVENT_NAME=pull_request BASE_REF=main FILE_PATTERNS="$patterns" FILE_LIMIT=50 MAX_DIFF_LINES=0 \
      GITHUB_OUTPUT="$OUT" GITHUB_STEP_SUMMARY="$work/run/summary.md" \
      bash "$work/step.sh"
  ) > "$work/run/stdout" 2> "$work/run/stderr"
  RC=$?
  set -e
  COUNT="$(sed -n 's/^count=//p' "$OUT")"
  FILES="$(awk '/^files<<EOF$/ { f = 1; next } /^EOF$/ { f = 0 } f' "$OUT")"
}

assert_has_file() {
  ok
  grep -qxF -- "$1" <<<"$FILES" || fail "file list lacks '$1' (got: $(tr '\n' ' ' <<<"$FILES"))"
}

found=0
for WF in .github/workflows/reusable-*.yml .github/workflows/reusable-*.yaml; do
  [ -f "$WF" ] || continue
  n="$(yq '[.jobs.*.steps[] | select(.env.FILE_PATTERNS != null)] | length' "$WF")"
  [ "$n" -gt 0 ] || continue
  found=$((found + 1))
  WF_SHORT="$(basename "$WF")"
  CASE="$WF_SHORT/extract"
  ok
  [ "$n" = 1 ] || { fail "expected one step binding FILE_PATTERNS, found $n"; continue; }
  yq '[.jobs.*.steps[] | select(.env.FILE_PATTERNS != null)] | .[0].run' "$WF" > "$work/step.sh"
  # shellcheck disable=SC2016 # a literal ${{, not a shell expansion
  yq -r '[.jobs.*.steps[] | select(.env.FILE_PATTERNS != null)] | .[0].env | to_entries | .[]
         | select((.value | tostring) | test("\$\{\{") | not) | .key + "\t" + (.value | tostring)' "$WF" > "$work/literal-env"
  ok
  [ -s "$work/step.sh" ] || { fail "empty run: body"; continue; }

  # 1. Root-level dotfile and file next to nested ones, with the workflow's
  #    own default patterns: one root and one nested file per pattern.
  CASE="$WF_SHORT/default-patterns"
  defaults="$(yq '.on.workflow_call.inputs.file-patterns.default' "$WF")"
  paths=()
  # `read -a` splits without globbing: an unquoted `**/*` would expand
  # against this checkout.
  read -r -a pats <<<"$defaults"
  for pat in "${pats[@]}"; do
    ext="${pat##*/}"; ext="${ext#\*}"
    [ -n "$ext" ] || ext=.txt
    paths+=("root$ext" "sub/dir/nested$ext")
  done
  [ "$defaults" = '**/*' ] && paths+=(.env.example .mcp.json)
  rm -rf "$work/repo"
  make_repo "$work/repo" "${paths[@]}"
  run_step "$work/repo" "$defaults"
  ok; [ "$RC" = 0 ] || fail "step exited $RC: $(head -c 300 "$work/run/stderr")"
  ok; [ "$COUNT" = "${#paths[@]}" ] || fail "count=$COUNT for ${#paths[@]} changed files matching '$defaults'"
  for p in "${paths[@]}"; do assert_has_file "$p"; done

  # 2. A caller's '**/*.py' must match a top-level server.py (pal-mcp-server).
  CASE="$WF_SHORT/caller-py"
  rm -rf "$work/repo"
  make_repo "$work/repo" server.py pkg/mod.py README.md
  run_step "$work/repo" '**/*.py'
  ok; [ "$RC" = 0 ] || fail "step exited $RC: $(head -c 300 "$work/run/stderr")"
  ok; [ "$COUNT" = 2 ] || fail "count=$COUNT, expected 2 (server.py, pkg/mod.py)"
  assert_has_file server.py
  assert_has_file pkg/mod.py
done

CASE=scan
ok
[ "$found" -gt 0 ] || fail "no reusable workflow step binds FILE_PATTERNS; the scan checked nothing"

if [ "$failures" -ne 0 ]; then
  printf 'FAIL: %s (%d of %d assertion(s) failed across %d workflow(s))\n' "$NAME" "$failures" "$checks" "$found"
  exit 1
fi
printf 'PASS: %s (%d assertion(s) across %d workflow(s))\n' "$NAME" "$checks" "$found"

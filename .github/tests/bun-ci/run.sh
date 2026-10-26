#!/usr/bin/env bash
# shellcheck disable=SC2016 # single-quoted ${{ }} and backticks are literal workflow/Markdown text
# Regression test for reusable-bun-ci.yml (#66, ported with the workflow).
#
# Part 1 scans EVERY workflow (.github/workflows/*.yml and *.yaml) for `run:`
# bodies that interpolate `${{ inputs.* }}` directly instead of reading them
# through `env:`. 17 such bodies in 13 files predate this test; they are
# allowlisted by file and count below, so the scan fails when any file gains
# one and when a new file (reusable-bun-ci.yml included) has any.
#
# Part 2 pins reusable-bun-ci.yml's static contract: permissions, secrets,
# pinning, concurrency, the setup-bun inputs, and the documented input set
# (every declared input is a row of README.md's "## Bun CI Workflow Inputs"
# table, with the declared default in its Default column).
#
# Part 3 EXTRACTS each step of the shipped reusable-bun-ci.yml with yq — its
# `if:`, `env:`, working directory and `run:` body — and executes the run bodies
# under the shell the job declares, with stub `bun`/`bunx`/`node` first on PATH.
# The inputs start from the workflow's own declared defaults. Nothing under
# test is retyped here.
#
# Needs: bash, yq v4 (mikefarah), git. No arguments.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

NAME=bun-ci
WF=.github/workflows/reusable-bun-ci.yml
ASSERTIONS=0

fail() {
  echo "FAIL: ${NAME}: $*" >&2
  exit 1
}
pass() { ASSERTIONS=$((ASSERTIONS + 1)); }
expect_eq() { # description, expected, actual
  [ "$2" = "$3" ] || fail "$1: expected [$2], got [$3]"
  pass
}

command -v yq >/dev/null 2>&1 || fail "yq (mikefarah v4) is not on PATH"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Part 1 — no `${{ inputs.* }}` interpolated into a run: body, across all files
# ---------------------------------------------------------------------------

# Pre-existing offenders at 0ec8861, counted with count_inputs_in_run below.
# Lower a count when a file is fixed; never raise one. A file not listed here
# (reusable-auto-fix.yml, reusable-auto-resolve-conflicts.yml, whose own tests
# forbid any `${{` in a run body) is allowed none.
BASELINE='reusable-a11y-aria.yml 1
reusable-a11y-wcag.yml 1
reusable-auto-merge-image-updater.yml 1
reusable-container-build.yml 4
reusable-container-release.yml 1
reusable-fix-release-conflicts.yml 1
reusable-npm-publish.yml 1
reusable-quality-async.yml 1
reusable-quality-code-smell.yml 1
reusable-quality-typescript.yml 1
reusable-security-deps.yml 2
reusable-security-owasp.yml 1
reusable-security-secrets.yml 1'

count_inputs_in_run() {
  yq '[.jobs[]?.steps[]? | select(has("run")) | select(.run | test("\$\{\{\s*inputs\."))] | length' "$1"
}

# Control: the scan must see an interpolated body and must not count an
# env-indirected one, or an empty result would read as a clean tree.
cat >"$TMP/control.yml" <<'YAML'
on: workflow_call
jobs:
  j:
    steps:
      - run: echo "${{ inputs.bad }}"
      - env:
          GOOD: ${{ inputs.good }}
        run: echo "$GOOD"
YAML
expect_eq "control: scan counts exactly the interpolated body" 1 "$(count_inputs_in_run "$TMP/control.yml")"

scanned=0
for f in .github/workflows/*.yml .github/workflows/*.yaml; do
  [ -f "$f" ] || continue
  scanned=$((scanned + 1))
  n=$(count_inputs_in_run "$f")
  allowed=$(printf '%s\n' "$BASELINE" | awk -v b="$(basename "$f")" '$1 == b { print $2 }')
  allowed=${allowed:-0}
  if [ "$n" -gt "$allowed" ]; then
    fail "$f: $n run: bodies interpolate \${{ inputs.* }} (allowed $allowed). Read the input through env: and reference \$VAR in the script."
  fi
  pass
done
[ "$scanned" -gt 20 ] || fail "only $scanned workflow files scanned — glob or checkout problem"

# ---------------------------------------------------------------------------
# Part 2 — static contract of reusable-bun-ci.yml
# ---------------------------------------------------------------------------

[ -f "$WF" ] || fail "$WF not found"
pass

wf() { yq "$1" "$WF"; }

expect_eq "exactly one job" 1 "$(wf '.jobs | length')"
expect_eq "workflow permissions" '{"contents":"read"}' "$(yq -o=json -I=0 '.permissions' "$WF")"
expect_eq "job declares no permissions of its own" null "$(wf '.jobs[].permissions')"
expect_eq "no secrets accepted" null "$(wf '.on.workflow_call.secrets')"
expect_eq "no workflow-level concurrency (job level, where the docs define it)" null "$(wf '.concurrency')"
group=$(wf '.jobs[].concurrency.group')
case "$group" in
  bun-ci-*) pass ;;
  *) fail "job concurrency group must start with 'bun-ci-' so it cannot equal the caller's group, got [$group]" ;;
esac
expect_eq "default shell" bash "$(wf '.jobs[].defaults.run.shell')"
expect_eq "default working directory" '${{ inputs.working-directory }}' "$(wf '.jobs[].defaults.run["working-directory"]')"

# Every action reference is a full commit SHA with a version comment.
uses_total=0
while IFS= read -r line; do
  uses_total=$((uses_total + 1))
  grep -Eq 'uses: [^@ ]+@[0-9a-f]{40} # v[0-9]' <<<"$line" ||
    fail "unpinned action reference: $line"
  pass
done < <(grep -E '^[[:space:]]*(- )?uses:' "$WF")
[ "$uses_total" -ge 4 ] || fail "expected at least 4 uses: lines, found $uses_total"

setup_bun='.jobs[].steps[] | select(.uses // "" | test("^oven-sh/setup-bun@"))'
expect_eq "setup-bun bun-version passthrough" '${{ inputs.bun-version }}' "$(wf "$setup_bun | .with[\"bun-version\"]")"
expect_eq "setup-bun gets no bun-version-file (warns on every run without packageManager)" false "$(wf "$setup_bun | .with | has(\"bun-version-file\")")"

# Documented concurrency: cancel in-progress runs on pull requests only.
expect_eq "cancel-in-progress only on pull_request" \
  "\${{ github.event_name == 'pull_request' }}" "$(wf '.jobs[].concurrency["cancel-in-progress"]')"

# The uses: steps are not executed in Part 3, so their with: blocks and if:
# guards are pinned here. The coverage path and cache key carry the
# working-directory prefix because uses: steps ignore defaults.run.
setup_node='.jobs[].steps[] | select(.uses // "" | test("^actions/setup-node@"))'
expect_eq "setup-node only when node-version is set" \
  "\${{ inputs.node-version != '' }}" "$(wf "$setup_node | .if")"
expect_eq "setup-node node-version passthrough" '${{ inputs.node-version }}' "$(wf "$setup_node | .with[\"node-version\"]")"

cache='.jobs[].steps[] | select(.uses // "" | test("^actions/cache@"))'
expect_eq "cache only when cache-dependencies is true" '${{ inputs.cache-dependencies }}' "$(wf "$cache | .if")"
# shellcheck disable=SC2088 # the literal path string in the workflow, not a shell path
expect_eq "cache path is bun's install cache" '~/.bun/install/cache' "$(wf "$cache | .with.path")"
expect_eq "cache key hashes <working-directory>/bun.lock" \
  "bun-install-\${{ runner.os }}-\${{ hashFiles(format('{0}/bun.lock', inputs.working-directory)) }}" \
  "$(wf "$cache | .with.key")"

coverage='.jobs[].steps[] | select(.id == "coverage")'
expect_eq "coverage step is upload-artifact" true "$(wf "$coverage | .uses | test(\"^actions/upload-artifact@\")")"
expect_eq "coverage only when coverage is true" '${{ inputs.coverage }}' "$(wf "$coverage | .if")"
expect_eq "coverage artifact name" coverage "$(wf "$coverage | .with.name")"
expect_eq "coverage path is <working-directory>/coverage/" \
  '${{ inputs.working-directory }}/coverage/' "$(wf "$coverage | .with.path")"
expect_eq "coverage fails when no files are found" error "$(wf "$coverage | .with[\"if-no-files-found\"]")"
expect_eq "coverage retention" 30 "$(wf "$coverage | .with[\"retention-days\"]")"

# An empty optional command skips its step rather than running a no-op eval,
# so the run page and step outcomes show it as skipped.
for step in typecheck test build; do
  expect_eq "$step step is skipped when its command is empty" \
    "\${{ inputs.$step-command != '' }}" "$(S=$step yq '.jobs[].steps[] | select(.id == strenv(S)) | .if' "$WF")"
done

expect_eq "declared inputs" \
  "build-command bun-version cache-dependencies coverage install-command node-version runner test-command timeout-minutes typecheck-command working-directory" \
  "$(wf '.on.workflow_call.inputs | keys | sort | join(" ")')"
expect_eq "install defaults to a frozen lockfile" 'bun install --frozen-lockfile' "$(wf '.on.workflow_call.inputs["install-command"].default')"
expect_eq "typecheck is opt-in" '' "$(wf '.on.workflow_call.inputs["typecheck-command"].default')"

# Documentation: every declared input is a row of README.md's Bun CI inputs
# table, and the row's Default column is the declared default ('' for empty).
doc_section=$(awk '/^## Bun CI Workflow Inputs/{on=1; next} on && /^##/{exit} on' README.md)
[ -n "$doc_section" ] || fail "README.md has no '## Bun CI Workflow Inputs' section"
doc_rows=0
for input in $(wf '.on.workflow_call.inputs | keys | .[]'); do
  doc_rows=$((doc_rows + 1))
  # Here-string, not `printf | grep -q`: grep -q exits on the first match and,
  # under pipefail, printf's SIGPIPE fails the pipeline intermittently.
  row=$(grep -F "| \`$input\` |" <<<"$doc_section" || true)
  [ -n "$row" ] || fail "input '$input' is not documented in README.md (## Bun CI Workflow Inputs)"
  pass
  default=$(K="$input" yq '.on.workflow_call.inputs[strenv(K)].default' "$WF")
  [ -n "$default" ] || default="''"
  # Columns: | Input | Type | Default | Description |
  documented=$(awk -F' [|] ' '{ print $3 }' <<<"$row")
  expect_eq "README default for '$input'" "\`$default\`" "$documented"
done
[ "$doc_rows" -gt 0 ] || fail "no inputs read from $WF"
grep -Fq '`reusable-bun-ci.yml`' README.md || fail "README.md does not list reusable-bun-ci.yml"
pass

# ---------------------------------------------------------------------------
# Part 3 — execute the extracted run: bodies against stub tools
# ---------------------------------------------------------------------------

SENTINEL='STUB-7f3a1c-not-the-real-tool'
mkdir -p "$TMP/bin"
for tool in bun bunx node; do
  cat >"$TMP/bin/$tool" <<'STUB'
#!/usr/bin/env bash
# Test stub. Logs tool|cwd|argv... and fails when any argument equals $STUB_FAIL_ARG.
{
  printf '%s|%s' "$(basename "$0")" "$PWD"
  for a in "$@"; do printf '|%s' "$a"; done
  printf '\n'
} >>"$STUB_LOG"
echo "STUB-7f3a1c-not-the-real-tool $(basename "$0") $*"
for a in "$@"; do
  if [ -n "${STUB_FAIL_ARG:-}" ] && [ "$a" = "$STUB_FAIL_ARG" ]; then exit 3; fi
done
exit 0
STUB
  chmod +x "$TMP/bin/$tool"
done
export PATH="$TMP/bin:$PATH"
export STUB_LOG="$TMP/probe.log"
for tool in bun bunx node; do
  expect_eq "$tool resolves to the stub" "$TMP/bin/$tool" "$(command -v "$tool")"
  grep -Fq "$SENTINEL" <<<"$("$tool" --probe)" || fail "$tool stub did not print its sentinel"
  pass
done

STEP_COUNT=$(wf '.jobs[].steps | length')
JOB_SHELL=$(wf '.jobs[].defaults.run.shell // ""')

var_name() { printf '%s_%s' "$1" "$(printf '%s' "$2" | tr -c 'A-Za-z0-9\n' '_')"; }

# Load the workflow's declared defaults, then apply fixture overrides.
set_input() { printf -v "$(var_name IN "$1")" '%s' "$2"; }
get_input() {
  local v
  v=$(var_name IN "$1")
  [ -n "${!v+x}" ] || fail "fixture references undeclared input '$1'"
  printf '%s' "${!v}"
}
reset_inputs() {
  local input
  for input in $(wf '.on.workflow_call.inputs | keys | .[]'); do
    set_input "$input" "$(K="$input" yq '.on.workflow_call.inputs[strenv(K)].default' "$WF")"
  done
}

# Resolve the only expression shapes the step env/working-directory use.
# Anything else fails, so a new expression forces this harness to learn it.
resolve() {
  local value=$1
  local re_input='^\$\{\{ inputs\.([A-Za-z0-9_-]+) \}\}$'
  local re_outcome='^\$\{\{ steps\.([A-Za-z0-9_-]+)\.outcome \}\}$'
  if [[ $value =~ $re_input ]]; then
    get_input "${BASH_REMATCH[1]}"
  elif [[ $value =~ $re_outcome ]]; then
    local v
    v=$(var_name OUT "${BASH_REMATCH[1]}")
    printf '%s' "${!v-}"
  elif [ "$value" = '${{ steps.setup-bun.outputs.bun-version }}' ]; then
    printf '%s' "1.9.9-stub"
  elif [ "$value" = '${{ github.workspace }}' ]; then
    printf '%s' "$WS"
  elif [[ $value == *'${{'* ]]; then
    fail "harness cannot resolve expression [$value]; teach resolve() about it"
  else
    printf '%s' "$value"
  fi
}

# Evaluate the only `if:` shapes the workflow uses; prior failure skips steps
# that use the implicit success() condition, as on a runner.
should_run() {
  local cond=$1
  local re_nonempty="^\\$\\{\\{ inputs\\.([A-Za-z0-9_-]+) != '' \\}\\}$"
  local re_bool='^\$\{\{ inputs\.([A-Za-z0-9_-]+) \}\}$'
  case "$cond" in
    'always()' | '${{ always() }}') return 0 ;;
  esac
  [ "$JOB_FAILED" -eq 0 ] || return 1
  if [ -z "$cond" ]; then
    return 0
  elif [[ $cond =~ $re_nonempty ]]; then
    local v
    v=$(get_input "${BASH_REMATCH[1]}") || exit 1
    [ -n "$v" ]
  elif [[ $cond =~ $re_bool ]]; then
    local v
    v=$(get_input "${BASH_REMATCH[1]}") || exit 1
    [ "$v" = "true" ]
  else
    fail "harness cannot evaluate if: [$cond]; teach should_run() about it"
  fi
}

run_job() { # runs every step of the extracted job in $WS; sets JOB_FAILED
  JOB_FAILED=0
  : >"$STUB_LOG"
  : >"$GITHUB_STEP_SUMMARY"
  local i id cond body wd_expr wd script rc key val
  for ((i = 0; i < STEP_COUNT; i++)); do
    id=$(I=$i yq '.jobs[].steps[env(I)].id // ""' "$WF")
    cond=$(I=$i yq '.jobs[].steps[env(I)].if // ""' "$WF")
    if ! should_run "$cond"; then
      [ -z "$id" ] || printf -v "$(var_name OUT "$id")" '%s' skipped
      continue
    fi
    if [ "$(I=$i yq '.jobs[].steps[env(I)] | has("run")' "$WF")" != true ]; then
      # uses: steps are not executed; record them as succeeded.
      [ -z "$id" ] || printf -v "$(var_name OUT "$id")" '%s' success
      continue
    fi
    body=$(I=$i yq '.jobs[].steps[env(I)].run' "$WF")
    wd_expr=$(I=$i yq '.jobs[].steps[env(I)]["working-directory"] // ""' "$WF")
    [ -n "$wd_expr" ] || wd_expr=$(wf '.jobs[].defaults.run["working-directory"] // ""')
    wd=$(resolve "$wd_expr") || exit 1
    case "$wd" in
      /*) ;;
      *) wd="$WS/$wd" ;;
    esac
    script="$TMP/step-$i.sh"
    printf '%s\n' "$body" >"$script"
    rc=0
    (
      while IFS=$'\t' read -r key val; do
        [ -n "$key" ] || continue
        val=$(resolve "$val") || exit 97
        export "$key=$val"
      done < <(I=$i yq '.jobs[].steps[env(I)].env // {} | to_entries | .[] | .key + "\t" + .value' "$WF")
      cd "$wd"
      if [ "$JOB_SHELL" = bash ]; then
        exec bash --noprofile --norc -eo pipefail "$script" # shell: bash
      else
        exec bash -e "$script" # the runner's default when no shell is set
      fi
    ) >"$TMP/step-$i.out" 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
      [ -z "$id" ] || printf -v "$(var_name OUT "$id")" '%s' success
    else
      [ -z "$id" ] || printf -v "$(var_name OUT "$id")" '%s' failure
      JOB_FAILED=1
    fi
  done
}

new_workspace() {
  WS=$(cd "$(mktemp -d "$TMP/ws.XXXX")" && pwd)
  mkdir -p "$WS/web"
  GITHUB_STEP_SUMMARY="$TMP/summary-$(basename "$WS").md"
  export GITHUB_STEP_SUMMARY
  unset STUB_FAIL_ARG
  for id in $(wf '.jobs[].steps[] | select(has("id")) | .id'); do
    unset "$(var_name OUT "$id")"
  done
  reset_inputs
}

expect_log() { # description, expected lines
  expect_eq "$1" "$2" "$(cat "$STUB_LOG")"
}
expect_summary() { # literal line fragment
  grep -Fq -- "$1" "$GITHUB_STEP_SUMMARY" || {
    cat "$GITHUB_STEP_SUMMARY" >&2
    fail "job summary lacks [$1]"
  }
  pass
}

# Case A — the declared defaults: install, test, build once each, in order,
# in the workspace root; typecheck (default '') never invokes a tool.
new_workspace
run_job
expect_eq "defaults: job succeeds" 0 "$JOB_FAILED"
expect_log "defaults: tool invocations" "bun|$WS|install|--frozen-lockfile
bun|$WS|run|test
bun|$WS|run|build"
expect_summary '- **Bun**: `1.9.9-stub`'
expect_summary '| Install | `bun install --frozen-lockfile` | success |'
expect_summary '| Type check | — | skipped (no command configured) |'
expect_summary '| Test | `bun run test` | success |'
expect_summary '| Build | `bun run build` | success |'
expect_summary '| Coverage artifact | — | skipped (coverage: false) |'

# Case B — subdirectory project, chained install, opt-in typecheck, argv with
# `--` and a quoted argument, empty build command, coverage on.
new_workspace
set_input working-directory web
set_input install-command 'bun install --frozen-lockfile && bun run db:generate'
set_input typecheck-command 'bunx tsc --noEmit'
set_input test-command 'bun run test -- --reporter=dot --grep "a b"'
set_input build-command ''
set_input coverage true
run_job
expect_eq "subdirectory: job succeeds" 0 "$JOB_FAILED"
expect_log "subdirectory: tool invocations" "bun|$WS/web|install|--frozen-lockfile
bun|$WS/web|run|db:generate
bunx|$WS/web|tsc|--noEmit
bun|$WS/web|run|test|--|--reporter=dot|--grep|a b"
expect_summary '- **Working directory**: `web`'
expect_summary '| Type check | `bunx tsc --noEmit` | success |'
expect_summary '| Build | — | skipped (no command configured) |'
expect_summary '| Coverage artifact | `web/coverage/` | success |'

# Case C — a failing test fails the job, skips the build, and the summary
# (if: always()) still records what happened.
new_workspace
export STUB_FAIL_ARG=test
run_job
expect_eq "failing test: job fails" 1 "$JOB_FAILED"
expect_log "failing test: build never runs" "bun|$WS|install|--frozen-lockfile
bun|$WS|run|test"
expect_summary '| Test | `bun run test` | failure |'
expect_summary '| Build | `bun run build` | skipped |'

# Case D — a failure on the left of a pipe fails the step (pipefail), and a
# `|` in a command is escaped in the summary table.
new_workspace
export STUB_FAIL_ARG=test
set_input test-command 'bun run test | cat'
run_job
expect_eq "piped failing test: job fails" 1 "$JOB_FAILED"
expect_summary '| Test | `bun run test \| cat` | failure |'

# Case E — a failing first half of a chained install stops the chain.
new_workspace
export STUB_FAIL_ARG=install
set_input install-command 'bun install --frozen-lockfile && bun run db:generate'
run_job
expect_eq "failing install: job fails" 1 "$JOB_FAILED"
expect_log "failing install: nothing after it runs" "bun|$WS|install|--frozen-lockfile"
expect_summary '| Install | `bun install --frozen-lockfile && bun run db:generate` | failure |'
expect_summary '| Test | `bun run test` | skipped |'

echo "PASS: ${NAME} (${ASSERTIONS} assertion(s))"

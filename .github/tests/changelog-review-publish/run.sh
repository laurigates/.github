#!/usr/bin/env bash
# Harness for the tracking-issue publication in reusable-changelog-review.yml.
#
# Before it, the triage agent ran `gh issue create --label … --assignee …`
# itself. On github.com gh files the issue first and assigns afterwards
# (replaceActorsForAssignable); when the token cannot assign, gh exits non-zero
# WITHOUT printing the URL of the issue it has already created, and the agent
# filed it again. laurigates/claude-plugins got two identical, unlabelled
# tracking issues per run (#2656/#2657, #2711/#2712), and the agent then wrote
# "labels were applied successfully" into the state file (claude-plugins#2720).
#
# The agent now only writes the issue body and its state-file entry; a bash
# step files the issue once, applies labels and assignee with the workflow
# token, reads them back, and writes the state file from what it read. This
# harness pins that split: the Claude step cannot file or push, and the
# publish step's EXTRACTED run: body is executed against a stub `gh` and a real
# git repository with a local bare remote. It never holds a retyped copy.
#
# Usage: bash .github/tests/changelog-review-publish/run.sh [workflow-file]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

WORKFLOW="$(pwd)/${1:-.github/workflows/reusable-changelog-review.yml}"

for tool in yq jq git; do
  command -v "$tool" >/dev/null || { echo "FATAL: $tool not found on PATH" >&2; exit 1; }
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

JOB=claude-triage
CLAUDE_STEP='Triage changelog into a tracking issue'
PUBLISH_STEP='Publish tracking issue and ratchet PR'

failures=0
checks=0
CASE_NAME=setup

fail() { printf '  FAIL [%s] %s\n' "$CASE_NAME" "$1"; failures=$((failures + 1)); }
ok()   { checks=$((checks + 1)); }
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

# ---------------------------------------------------------------- extraction
step_field() { # <step name> <yq path relative to the step>
  STEP="$1" yq -r ".jobs[\"$JOB\"].steps[] | select(.name == strenv(STEP)) | ($2) // \"\"" "$WORKFLOW"
}

echo "== changelog-review-publish against $WORKFLOW"

# ----------------------------------------------------------------- structure
CASE_NAME=structure
names="$(yq -r ".jobs[\"$JOB\"].steps[].name // \"\"" "$WORKFLOW")"
pos() { printf '%s\n' "$names" | { grep -nxF -- "$1" || true; } | cut -d: -f1; }
p_claude="$(pos "$CLAUDE_STEP")"
p_publish="$(pos "$PUBLISH_STEP")"
ok; [ -n "$p_claude" ] || fail "no '$CLAUDE_STEP' step in job $JOB"
ok; [ -n "$p_publish" ] || fail "no '$PUBLISH_STEP' step: nothing but the agent would file the tracking issue"
ok
if [ -n "$p_claude" ] && [ -n "$p_publish" ] && [ "$p_claude" -ge "$p_publish" ]; then
  fail "'$PUBLISH_STEP' must run after '$CLAUDE_STEP' (got $p_publish <= $p_claude)"
fi

# The agent must not be ABLE to file, push or open a PR, not only be told not to.
args="$(step_field "$CLAUDE_STEP" .with.claude_args)"
assert_contains "$args" '--allowedTools' "Claude step claude_args"
for granted in 'gh issue create' 'gh issue new' 'gh pr create' 'git push' 'git commit' \
               'Bash(gh issue *)' 'Bash(gh pr *)' 'Bash(gh *)' 'Bash(git *)' 'Bash(*)'; do
  assert_lacks "$args" "$granted" "Claude step --allowedTools"
done

prompt="$(step_field "$CLAUDE_STEP" .with.prompt)"
for cmd in 'gh issue create' 'gh pr create' 'git push' '--assignee' '--label'; do
  assert_lacks "$prompt" "$cmd" "Claude prompt"
done

# The prompt and the publish step must name the same two hand-off files.
body_file="$(step_field "$PUBLISH_STEP" .env.BODY_FILE)"
entry_file="$(step_field "$PUBLISH_STEP" .env.ENTRY_FILE)"
ok; [ -n "$body_file" ] || fail "'$PUBLISH_STEP' does not set BODY_FILE"
ok; [ -n "$entry_file" ] || fail "'$PUBLISH_STEP' does not set ENTRY_FILE"
assert_contains "$prompt" "\`$body_file\`" "Claude prompt (body hand-off file)"
assert_contains "$prompt" "\`$entry_file\`" "Claude prompt (entry hand-off file)"

# Labels and assignee go through the workflow's own token (issues: write), not
# the PAT that could not assign.
# shellcheck disable=SC2016 # literal GitHub expressions, not shell ones
while IFS='|' read -r key want; do
  assert_eq "$(step_field "$PUBLISH_STEP" ".env.$key")" "$want" "'$PUBLISH_STEP' env $key"
done <<'WIRING'
META_TOKEN|${{ github.token }}
GH_TOKEN|${{ secrets.RELEASE_PLEASE_TOKEN || github.token }}
ISSUE_TITLE|Review Claude Code changelog: ${{ needs.check-changelog.outputs.previous_version }} → ${{ needs.check-changelog.outputs.effective_latest }}
ISSUE_LABELS|${{ inputs.issue-labels }}
ASSIGNEE|${{ inputs.issue-assignee || github.repository_owner }}
VERSION_FILE|${{ inputs.version-file }}
EFFECTIVE_LATEST|${{ needs.check-changelog.outputs.effective_latest }}
WINDOWED|${{ needs.check-changelog.outputs.windowed }}
COMMIT_TYPE_SCOPE|${{ inputs.commit-type-scope }}
WIRING

step_field "$PUBLISH_STEP" .run > "$work/publish.sh"
ok; [ -s "$work/publish.sh" ] || fail "'$PUBLISH_STEP' has no run: body"
# shellcheck disable=SC2016 # a literal GitHub expression, not a shell one
assert_lacks "$(cat "$work/publish.sh")" '${{' "publish run body (inputs come from env:)"

if [ "$failures" -gt 0 ] || [ ! -s "$work/publish.sh" ]; then
  printf '\nFAILED: %d of %d checks (structure); behaviour not exercised\n' "$failures" "$checks"
  exit 1
fi

# ------------------------------------------------------------------ gh stub
# Records every call; answers from files under $STUB. Prints a sentinel on
# --stub-sentinel so the harness can prove this stub, not the real gh, runs.
mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = "--stub-sentinel" ] && { echo GH_STUB; exit 0; }
S="$STUB"
printf '%s\ttoken=%s\n' "$*" "${GH_TOKEN:-}" >> "$S/calls"
case "$1 ${2:-}" in
  "issue list")
    if [ -f "$S/created" ] && [ -f "$S/list-after-create.json" ]; then cat "$S/list-after-create.json"
    else cat "$S/list.json"; fi ;;
  "issue create")
    touch "$S/created"
    if [ -f "$S/create-fails" ]; then echo "GraphQL: could not assign (replaceActorsForAssignable)" >&2; exit 1; fi
    echo "https://github.com/o/r/issues/101" ;;
  "pr create")
    echo "https://github.com/o/r/pull/102" ;;
  "api "*)
    method=GET path=
    shift
    while [ $# -gt 0 ]; do
      case "$1" in
        -X) method="$2"; shift 2 ;;
        --input) shift 2 ;;
        *) path="$1"; shift ;;
      esac
    done
    num="$(printf '%s' "$path" | sed -n 's#^repos/[^/]*/[^/]*/issues/\([0-9]*\).*#\1#p')"
    case "$method $path" in
      "POST "*/labels)
        jq -c '.labels[]' >> "$S/labels-$num" ;;
      "POST "*/assignees)
        if [ -f "$S/drop-assignee" ]; then cat > /dev/null; else jq -c '.assignees[]' >> "$S/assignees-$num"; fi ;;
      "GET "*)
        jq -n --slurpfile l <(cat "$S/labels-$num" 2>/dev/null || true) \
              --slurpfile a <(cat "$S/assignees-$num" 2>/dev/null || true) \
              '{number: 0, labels: [$l[] | {name: .}], assignees: [$a[] | {login: .}]}' ;;
      *) echo "stub: unhandled api $method $path" >&2; exit 64 ;;
    esac ;;
  *) echo "stub: unhandled gh $*" >&2; exit 64 ;;
esac
STUB
chmod +x "$work/bin/gh"

CASE_NAME=stub
ok
[ "$(PATH="$work/bin:$PATH" command -v gh)" = "$work/bin/gh" ] \
  || fail "the gh stub is not the gh on PATH; the real gh would run"
assert_eq "$(PATH="$work/bin:$PATH" gh --stub-sentinel)" GH_STUB "gh stub sentinel"

# ------------------------------------------------------------------ fixture
TITLE='Review Claude Code changelog: 2.1.290 → 2.1.300'
seed_state() {
  cat <<'JSON'
{
  "lastCheckedVersion": "2.1.290",
  "lastCheckedDate": "2026-09-14",
  "changelogUrl": "https://example.invalid/CHANGELOG.md",
  "reviewedChanges": [
    {
      "version": "2.1.290",
      "date": "2026-09-14",
      "relevantChanges": [
        "older entry"
      ],
      "actionsRequired": [
        "See issue #5"
      ]
    }
  ]
}
JSON
}

# setup_case <name>: a fresh caller checkout with a bare origin, the agent's two
# hand-off files, and an empty stub state.
setup_case() {
  CASE_NAME="$1"
  C="$work/case-$1"
  rm -rf "$C"
  mkdir -p "$C/stub"
  git init -q --bare "$C/origin.git"
  git init -q -b main "$C/repo"
  (
    cd "$C/repo"
    git config user.name harness
    git config user.email harness@example.invalid
    git config core.hooksPath /dev/null   # a developer's global hooks must not run here
    seed_state > .claude-code-version-check.json
    echo "# repo" > README.md
    git add .claude-code-version-check.json README.md
    git commit -q -m init
    git remote add origin "$C/origin.git"
    git push -q origin main
  )
  printf '%s\n' '## Follow-up tasks' '' '### hooks-reference.md' '- 2.1.295: new hook event' > "$C/repo/triage-issue-body.md"
  jq -n '{relevantChanges: ["2.1.295 adds a hook event"], actionsRequired: ["Update hooks-reference.md per the tracking issue"]}' \
    > "$C/repo/triage-entry.json"
  echo '[]' > "$C/stub/list.json"
}

run_publish() {
  : > "$C/output"; : > "$C/summary"
  set +e
  (
    cd "$C/repo"
    env PATH="$work/bin:$PATH" STUB="$C/stub" \
      GITHUB_REPOSITORY=o/r GITHUB_OUTPUT="$C/output" GITHUB_STEP_SUMMARY="$C/summary" \
      GH_TOKEN=pat-token META_TOKEN=workflow-token \
      ISSUE_TITLE="$TITLE" BODY_FILE="$body_file" ENTRY_FILE="$entry_file" \
      ISSUE_LABELS='changelog-review, maintenance' ASSIGNEE=laurigates \
      VERSION_FILE=.claude-code-version-check.json EFFECTIVE_LATEST=2.1.300 WINDOWED=false \
      COMMIT_TYPE_SCOPE='chore(project-plugin)' \
      bash --noprofile --norc -eo pipefail "$work/publish.sh"
  ) > "$C/stdout" 2> "$C/stderr"
  RC=$?
  set -e
  CALLS="$(cat "$C/stub/calls" 2>/dev/null || true)"
}
count_calls() { printf '%s\n' "$CALLS" | grep -c -- "^$1" || true; }
state() { jq -r "$1" "$C/repo/.claude-code-version-check.json"; }
remote_state() { git -C "$C/repo" show "origin/chore/changelog-triage-2.1.300:.claude-code-version-check.json" | jq -r "$1"; }

# ------------------------------------------------------------ fresh range
setup_case fresh
run_publish
assert_eq "$RC" 0 "exit code (stderr: $(tail -n 3 "$C/stderr" | tr '\n' ' '))"
assert_eq "$(count_calls 'issue create')" 1 "gh issue create calls"
create_call="$(printf '%s\n' "$CALLS" | grep '^issue create' || true)"
assert_lacks "$create_call" '--assignee' "issue create (assignment is a separate, verified call)"
assert_lacks "$create_call" '--label' "issue create (labels are a separate, verified call)"
assert_contains "$create_call" "--body-file $body_file" "issue create"
assert_contains "$create_call" 'token=pat-token' "issue create token"
assert_contains "$CALLS" $'api -X POST repos/o/r/issues/101/labels --input -\ttoken=workflow-token' "issue labels via workflow token"
assert_contains "$CALLS" $'api -X POST repos/o/r/issues/101/assignees --input -\ttoken=workflow-token' "issue assignee via workflow token"
git -C "$C/repo" fetch -q origin
assert_eq "$(remote_state .lastCheckedVersion)" 2.1.300 "pushed lastCheckedVersion"
assert_eq "$(remote_state '.reviewedChanges | length')" 2 "pushed reviewedChanges length"
assert_eq "$(remote_state '.reviewedChanges[0].version')" 2.1.300 "new entry version"
assert_eq "$(remote_state '.reviewedChanges[0].relevantChanges[0]')" '2.1.295 adds a hook event' "new entry relevantChanges"
assert_contains "$(remote_state '.reviewedChanges[0].actionsRequired[0]')" '#101' "new entry cites the filed issue"
assert_eq "$(remote_state '.reviewedChanges[0].actionsRequired[1]')" 'Update hooks-reference.md per the tracking issue' "agent action kept"
verified="$(remote_state '.reviewedChanges[0].actionsRequired[-1]')"
assert_contains "$verified" 'changelog-review, maintenance' "verified-metadata line (labels)"
assert_contains "$verified" 'laurigates' "verified-metadata line (assignee)"
assert_lacks "$verified" 'NOT' "verified-metadata line (all applied)"
assert_eq "$(git -C "$C/repo" diff --name-only origin/main origin/chore/changelog-triage-2.1.300)" .claude-code-version-check.json "ratchet PR changes only the state file"
assert_eq "$(git -C "$C/repo" rev-list --count origin/main..origin/chore/changelog-triage-2.1.300)" 1 "ratchet commits"
assert_eq "$(count_calls 'pr create')" 1 "gh pr create calls"
pr_call="$(printf '%s\n' "$CALLS" | grep '^pr create' || true)"
assert_lacks "$pr_call" '--assignee' "pr create"
assert_contains "$CALLS" $'api -X POST repos/o/r/issues/102/labels --input -\ttoken=workflow-token' "PR labels via workflow token"
assert_eq "$(sed -n 's/^issue_number=//p' "$C/output")" 101 "issue_number output"

# ------------------------------------------------ an open issue already exists
setup_case existing
jq -n --arg t "$TITLE" '[{number: 77, title: $t}, {number: 90, title: "unrelated"}]' > "$C/stub/list.json"
run_publish
assert_eq "$RC" 0 "exit code (stderr: $(tail -n 3 "$C/stderr" | tr '\n' ' '))"
assert_eq "$(count_calls 'issue create')" 0 "gh issue create calls"
assert_contains "$(state '.reviewedChanges[0].actionsRequired[0]')" '#77' "entry cites the existing issue"
assert_contains "$CALLS" 'api -X POST repos/o/r/issues/77/labels' "labels applied to the existing issue"

# ------------------- create exits non-zero AFTER the issue exists (the #2720 path)
setup_case create-fails-after-filing
touch "$C/stub/create-fails"
jq -n --arg t "$TITLE" '[{number: 101, title: $t}]' > "$C/stub/list-after-create.json"
run_publish
assert_eq "$RC" 0 "exit code (stderr: $(tail -n 3 "$C/stderr" | tr '\n' ' '))"
assert_eq "$(count_calls 'issue create')" 1 "gh issue create calls (never retried)"
assert_contains "$(state '.reviewedChanges[0].actionsRequired[0]')" '#101' "entry cites the issue the failed call filed"

# ------------------------- create fails and no issue exists: fail, file nothing
setup_case create-fails
touch "$C/stub/create-fails"
run_publish
ok; [ "$RC" -ne 0 ] || fail "expected a non-zero exit when no issue could be filed"
assert_eq "$(count_calls 'issue create')" 1 "gh issue create calls (never retried)"
assert_eq "$(count_calls 'pr create')" 0 "gh pr create calls"

# ------------------------------- assignee silently ignored by the API
setup_case assignee-dropped
touch "$C/stub/drop-assignee"
run_publish
assert_eq "$RC" 0 "exit code (stderr: $(tail -n 3 "$C/stderr" | tr '\n' ' '))"
verified="$(state '.reviewedChanges[0].actionsRequired[-1]')"
assert_contains "$verified" 'NOT' "verified-metadata line reports the missing assignee"
assert_contains "$(cat "$C/stdout")" '::warning::' "stdout warning"

# ------------------------------------ malformed agent entry: fail before filing
setup_case bad-entry
echo '{"relevantChanges": "not an array"}' > "$C/repo/triage-entry.json"
run_publish
ok; [ "$RC" -ne 0 ] || fail "expected a non-zero exit for a malformed entry file"
assert_eq "$(count_calls 'issue create')" 0 "gh issue create calls"
assert_eq "$(state .lastCheckedVersion)" 2.1.290 "state file untouched"

# ------------------------------------------ empty issue body: fail before filing
setup_case empty-body
: > "$C/repo/triage-issue-body.md"
run_publish
ok; [ "$RC" -ne 0 ] || fail "expected a non-zero exit for an empty issue body"
assert_eq "$(count_calls 'issue create')" 0 "gh issue create calls"

# ---------------------- the agent edited the state file itself: harness wins
setup_case agent-edited-state
jq '.lastCheckedVersion = "9.9.9"' "$C/repo/.claude-code-version-check.json" > "$C/tmp.json"
mv "$C/tmp.json" "$C/repo/.claude-code-version-check.json"
run_publish
assert_eq "$RC" 0 "exit code (stderr: $(tail -n 3 "$C/stderr" | tr '\n' ' '))"
assert_eq "$(state .lastCheckedVersion)" 2.1.300 "lastCheckedVersion comes from the workflow"
assert_eq "$(state '.reviewedChanges | length')" 2 "exactly one new entry"

echo
if [ "$failures" -gt 0 ]; then
  printf 'FAILED: %d of %d checks\n' "$failures" "$checks"
  exit 1
fi
printf 'PASS: %d checks\n' "$checks"

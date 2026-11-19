#!/usr/bin/env bash
# issue-enrich — reusable-issue-enrich.yml.
#
# 1. Static: the enrich job runs only on issues the owner opened that carry no
#    marker; its token cannot write; the agent's tools are Read, Grep, Glob
#    and Write, with one extra directory that is not $RUNNER_TEMP itself; the
#    publish job runs no model and holds no secret; no run: body expands an
#    expression.
# 2. Fixtures: the shipped "Edit the issue" and "Apply labels" bodies, run
#    against a stub gh and a stand-in for issue-labels.py. The edit keeps the
#    original text, leaves an issue the owner edited meanwhile alone, refuses
#    a malformed draft, and writes nothing on a dry run. Labels: only the
#    `add` lists are posted, and needs: labels and `blocked` never reach
#    validate.
#
# Usage: .github/tests/issue-enrich/run.sh [workflow]
# Requires: yq (mikefarah v4), jq, python3.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

WF="${1:-.github/workflows/reusable-issue-enrich.yml}"
command -v yq >/dev/null || { echo "FAIL: issue-enrich: yq is required" >&2; exit 1; }
command -v jq >/dev/null || { echo "FAIL: issue-enrich: jq is required" >&2; exit 1; }
[ -f "$WF" ] || { echo "FAIL: issue-enrich: $WF not found" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0
checks=0
CASE=""
fail() { printf '  FAIL [%s] %s\n' "$CASE" "$1"; failures=$((failures + 1)); }
ok() { checks=$((checks + 1)); }
is() { ok; [ "$2" = "$3" ] || fail "$1: wanted '$3', got '$2'"; }
has() { ok; grep -qF -- "$2" <<<"$1" || fail "missing '$2' in: $(tr '\n' ' ' <<<"$1" | cut -c1-400)"; }
lacks() { ok; if grep -qF -- "$2" <<<"$1"; then fail "unexpected '$2' in: $(tr '\n' ' ' <<<"$1" | cut -c1-400)"; fi; }

# ------------------------------------------------------------ 1. static
CASE=static
gate="$(yq '.jobs.enrich.if' "$WF")"
for want in "github.event.action == 'opened'" "author_association == 'OWNER'" \
  "github.event.issue.user.type != 'Bot'" "github.event.sender.type != 'Bot'" "'<!-- issue-enrich'" \
  "!contains(github.event.issue.body || '', '## ')"; do
  has "$gate" "$want"
done
perms="$(yq -o=json -I=0 '.jobs.enrich.permissions' "$WF")"
is "enrich job permissions" "$perms" '{"contents":"read","issues":"read","id-token":"write"}'
args="$(yq '.jobs.enrich.steps[] | select(.uses == "anthropics/claude-code-action*") | .with.claude_args' "$WF")"
has "$args" '--allowedTools "Read,Grep,Glob,Write"'
has "$args" '--disallowedTools "Bash,WebFetch,WebSearch"'
has "$args" '--add-dir ${{ runner.temp }}/issue-enrich'
ok; [ "$(grep -c -- '--add-dir' <<<"$args")" -eq 1 ] || fail "the agent gets more than one extra directory"
publish="$(yq '.jobs.publish' "$WF")"
lacks "$publish" 'claude-code-action'
lacks "$publish" 'secrets.'
ok; [ "$(yq '.jobs.publish.needs' "$WF")" = enrich ] || fail "publish does not wait for enrich"
ok
if yq '.jobs[].steps[] | select(has("run")) | .run' "$WF" | grep -F '${{' >/dev/null; then
  fail "a run: body expands an expression; pass values through env:"
fi

# ------------------------------------------------------------ 2. fixtures
body() {
  STEP="$1" yq -e '.jobs.publish.steps[] | select(.name == strenv(STEP)) | .run' "$WF" >"$2" 2>/dev/null || true
  [ -s "$2" ] || { echo "FATAL: step '$1' not found in the publish job of $WF" >&2; exit 1; }
}
body 'Edit the issue' "$work/edit.sh"
body 'Apply labels' "$work/labels.sh"

mkdir -p "$work/bin" "$work/ws/.issue-labels/git-plugin/scripts" "$work/stub"
cat >"$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
# Stub gh: logs each call and the JSON it is handed; answers the issue read.
if [ "${1:-}" = --stub-sentinel ]; then echo STUB_GH_ISSUE_ENRICH; exit 0; fi
printf '%s\n' "$*" >>"$GH_LOG"
prev=""
for arg in "$@"; do
  if [ "$prev" = --input ]; then
    if [ "$arg" = - ]; then printf 'INPUT %s\n' "$(cat)" >>"$GH_LOG"; else printf 'INPUT %s\n' "$(jq -c . "$arg")" >>"$GH_LOG"; fi
  fi
  prev="$arg"
done
case "$*" in
  "api repos/o/r/issues/7 --jq "*) printf '%s\n' "$STUB_CURRENT" ;;
esac
exit 0
EOF
chmod +x "$work/bin/gh"
cat >"$work/ws/.issue-labels/git-plugin/scripts/issue-labels.py" <<'EOF'
import os, sys

args = sys.argv[1:]
with open(os.environ["PY_LOG"], "a") as log:
    log.write("ARGS " + " ".join(args) + "\n")
    if "--labels-file" in args:
        with open(args[args.index("--labels-file") + 1]) as fh:
            log.write("PROPOSALS " + fh.read().replace("\n", " ") + "\n")
path = os.path.join(os.environ["STUB_DIR"], args[0] + ".out")
if os.path.exists(path):
    sys.stdout.write(open(path).read())
EOF

CASE=stubs
ok
if [ "$(PATH="$work/bin:$PATH" gh --stub-sentinel 2>/dev/null)" != STUB_GH_ISSUE_ENRICH ]; then
  echo "FATAL: the stub gh is not the gh on PATH; refusing to run step bodies against the real one" >&2
  exit 1
fi

# event <title> <body>: the payload the caller's `issues: opened` carried.
event() { jq -n --arg t "$1" --arg b "$2" '{action: "opened", issue: {number: 7, title: $t, body: $b}}' >"$work/event.json"; }
# draft <file> <content>: one file of the agent's output.
draft() { printf '%s' "$2" >"$work/draft/$1"; }
reset() { rm -rf "$work/draft" "$work/stub"; mkdir -p "$work/draft" "$work/stub"; }

run() {
  local script="$1"
  shift
  : >"$work/gh.log"
  : >"$work/py.log"
  : >"$work/summary.md"
  rm -rf "$work/tmp"
  mkdir -p "$work/tmp"
  RC=0
  OUT="$(cd "$work/ws" && env -i PATH="$work/bin:$PATH" HOME="$work" GH_LOG="$work/gh.log" PY_LOG="$work/py.log" \
    STUB_DIR="$work/stub" GITHUB_STEP_SUMMARY="$work/summary.md" GITHUB_EVENT_PATH="$work/event.json" \
    RUNNER_TEMP="$work/tmp" REPO=o/r NUMBER=7 DRY_RUN=false DRAFT="$work/draft" TAXONOMY_PATH=.github/issue-labels.json \
    STUB_CURRENT="${STUB_CURRENT:-}" "$@" bash -e "$script" 2>&1 </dev/null)" || RC=$?
  LOG="$(cat "$work/gh.log")"
  PY="$(cat "$work/py.log")"
}
patches() { grep -c '^api -X PATCH' "$work/gh.log" || true; }
posts() { grep -c '^api -X POST' "$work/gh.log" || true; }
new_body() { sed -n 's/^INPUT //p' "$work/gh.log" | head -n 1 | jq -r '.body'; }
new_title() { sed -n 's/^INPUT //p' "$work/gh.log" | head -n 1 | jq -r '.title'; }

orig_title='enrich issues'
orig_body='claude should fix up my short issues'
current() { jq -nc --arg t "$1" --arg b "$2" '{title: $t, body: $b}'; }

CASE=edit-pass
reset
event "$orig_title" "$orig_body"
draft title.txt $'[Feature] issue-labels: enrich terse owner issues\n'
draft body.md $'## What\n\nRewrite.\n<!-- issue-enrich: v1 -->\n'
STUB_CURRENT="$(current "$orig_title" "$orig_body")" run "$work/edit.sh"
is "exit" "$RC" 0
is "PATCH calls" "$(patches)" 1
is "title" "$(new_title)" '[Feature] issue-labels: enrich terse owner issues'
b="$(new_body)"
has "$b" $'## What\n\nRewrite.\n\n<details>'
has "$b" '<summary>Original issue text</summary>'
has "$b" $'```text\nenrich issues\n\nclaude should fix up my short issues\n```'
is "markers in the new body" "$(grep -c '<!-- issue-enrich: v1 -->' <<<"$b")" 1
is "the body ends with the marker" "$(tail -n 1 <<<"$b")" '<!-- issue-enrich: v1 -->'

CASE=edit-fence
reset
fenced=$'see:\n```sh\nls\n```'
event "$orig_title" "$fenced"
draft title.txt 'Better title'
draft body.md 'Body.'
STUB_CURRENT="$(current "$orig_title" "$fenced")" run "$work/edit.sh"
is "exit" "$RC" 0
b="$(new_body)"
has "$b" $'````text\nenrich issues'
has "$b" $'```\n````\n\n</details>'

CASE=edit-owner-edited
reset
event "$orig_title" "$orig_body"
draft title.txt 'Better title'
draft body.md 'Body.'
STUB_CURRENT="$(current "$orig_title" "$orig_body, and more")" run "$work/edit.sh"
is "exit" "$RC" 0
is "PATCH calls" "$(patches)" 0
has "$OUT" "the owner's version is kept"

CASE=edit-already-enriched
reset
event "$orig_title" "$orig_body"
draft title.txt 'Better title'
draft body.md 'Body.'
STUB_CURRENT="$(current "$orig_title" $'x\n<!-- issue-enrich: v1 -->')" run "$work/edit.sh"
is "exit" "$RC" 0
is "PATCH calls" "$(patches)" 0
has "$OUT" "already enriched"

CASE=edit-two-line-title
reset
event "$orig_title" "$orig_body"
draft title.txt $'one\ntwo'
draft body.md 'Body.'
STUB_CURRENT="$(current "$orig_title" "$orig_body")" run "$work/edit.sh"
is "exit" "$RC" 1
is "gh calls" "$LOG" ""

CASE=edit-no-body
reset
event "$orig_title" "$orig_body"
draft title.txt 'Better title'
STUB_CURRENT="$(current "$orig_title" "$orig_body")" run "$work/edit.sh"
is "exit" "$RC" 1
is "gh calls" "$LOG" ""

CASE=edit-skip
reset
event "$orig_title" "$orig_body"
draft skip.txt 'already clear'
run "$work/edit.sh"
is "exit" "$RC" 0
is "gh calls" "$LOG" ""
has "$OUT" "already clear"

CASE=edit-dry-run
reset
event "$orig_title" "$orig_body"
draft title.txt 'Better title'
draft body.md 'Body.'
STUB_CURRENT="$(current "$orig_title" "$orig_body")" run "$work/edit.sh" DRY_RUN=true
is "exit" "$RC" 0
is "PATCH calls" "$(patches)" 0
has "$OUT" "Dry run: would set the title of #7 to: Better title"

CASE=edit-dry-run-unset
reset
event "$orig_title" "$orig_body"
draft title.txt 'Better title'
draft body.md 'Body.'
STUB_CURRENT="$(current "$orig_title" "$orig_body")" run "$work/edit.sh" DRY_RUN=
is "PATCH calls" "$(patches)" 0

CASE=labels-pass
reset
printf '%s' '{"status":"OK","number":7,"add":["enhancement"],"dropped":[]}' >"$work/stub/classify.out"
printf '%s' '{"status":"OK","number":7,"add":["area:issue-labels"],"dropped":[]}' >"$work/stub/validate.out"
draft labels.json '{"labels":[{"name":"area:issue-labels","evidence":"x"},{"name":"needs:decision","evidence":"y"},{"name":" Blocked ","evidence":"z"},"bare"]}'
run "$work/labels.sh"
is "exit" "$RC" 0
is "POST calls" "$(posts)" 2
has "$LOG" 'INPUT {"labels":["enhancement"]}'
has "$LOG" 'INPUT {"labels":["area:issue-labels"]}'
has "$PY" 'ARGS classify --repo o/r --issue 7 --taxonomy-path .github/issue-labels.json'
has "$PY" 'area:issue-labels'
lacks "$PY" 'needs:decision'
lacks "$PY" 'Blocked'
lacks "$PY" 'bare'

CASE=labels-dry-run
reset
printf '%s' '{"status":"OK","number":7,"add":["enhancement"],"dropped":[]}' >"$work/stub/classify.out"
printf '%s' '{"status":"OK","number":7,"add":["area:issue-labels"],"dropped":[]}' >"$work/stub/validate.out"
draft labels.json '{"labels":[{"name":"area:issue-labels","evidence":"x"}]}'
run "$work/labels.sh" DRY_RUN=true
is "exit" "$RC" 0
is "POST calls" "$(posts)" 0
has "$OUT" 'Dry run: model would add to #7: `area:issue-labels`'

CASE=labels-no-proposals
reset
printf '%s' '{"status":"OK","number":7,"add":["enhancement"],"dropped":[]}' >"$work/stub/classify.out"
draft labels.json 'not json'
run "$work/labels.sh"
is "exit" "$RC" 0
is "POST calls" "$(posts)" 1
has "$OUT" 'no usable labels.json'
lacks "$PY" 'ARGS validate'

CASE=labels-bad-classify
reset
printf '%s' '{"status":"ERROR"}' >"$work/stub/classify.out"
draft labels.json '{"labels":[]}'
run "$work/labels.sh"
is "exit" "$RC" 1
is "POST calls" "$(posts)" 0

if [ "$failures" -gt 0 ]; then
  echo "FAILED: $failures of $checks checks"
  exit 1
fi
echo "PASS: issue-enrich ($checks assertion(s))"

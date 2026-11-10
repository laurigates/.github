#!/usr/bin/env bash
# Tests for reusable-issue-labels.yml.
#
# Part 1 reads the parsed workflow (yq, so comments are gone) and checks what
# keeps it from looping or leaking: every token is `github.token`, no `run:`
# body contains an expression, no issue or PR title or body is referenced
# anywhere, nothing handles a label event, every write call is a POST to an
# issue's labels, comments or assignees (never an edit), every job runs the
# pinned script and never checks out the calling repository, and no job asks
# for more than the documented caller grant.
#
# Part 2 EXTRACTS the shipped step bodies (no retyped copy) and runs them
# against a stub `gh` that logs every call and its stdin, and a stand-in for
# issue-labels.py that logs its arguments and prints a canned result. The
# script's own decisions are tested in laurigates/claude-plugins
# (git-plugin/scripts/tests/test-issue-labels.sh); these cases check only what
# the steps add: a dry run writes nothing, a step writes only when DRY_RUN is
# exactly `false`, a normal run sends exactly the labels classify returned,
# a malformed result applies nothing, an absent taxonomy is not a provision
# failure, the audit issue is filed once and commented on only when the
# findings change, and backfill stops at max-issues.
#
# Usage: bash .github/tests/issue-labels/run.sh [workflow]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

NAME=issue-labels
WF="${1:-.github/workflows/reusable-issue-labels.yml}"
for tool in yq jq python3; do
  command -v "$tool" >/dev/null || { echo "FATAL: $tool is required" >&2; exit 1; }
done
[ -f "$WF" ] || { echo "FATAL: $WF does not exist" >&2; exit 1; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0
checks=0
CASE=static
fail() { printf '  FAIL [%s] %s\n' "$CASE" "$1"; failures=$((failures + 1)); }
ok() { checks=$((checks + 1)); }

# ------------------------------------------------------------ 1. static
yq -o=json '.' "$WF" >"$work/doc.json"
static="$(python3 - "$work/doc.json" 2>&1 <<'PY' || true
import json, re, sys

with open(sys.argv[1]) as fh:
    wf = json.load(fh) or {}
errs, n = [], 0


def check(cond, msg):
    global n
    n += 1
    if not cond:
        errs.append(msg)


TOKEN = "${{ github.token }}"
LEVEL = {None: 0, "none": 0, "read": 1, "write": 2}
ALLOWED_WRITE = re.compile(
    r'-X\s+POST\s+"repos/\$REPO/issues/\$[A-Za-z_]+/(labels|comments|assignees)"'
)
ALLOWED_GH = {("issue", "list"), ("issue", "create"), ("label", "list")}


def leaves(node, path=""):
    """Every key and string value in the document, with its path."""
    if isinstance(node, dict):
        for k, v in node.items():
            yield f"{path}.{k}", str(k)
            yield from leaves(v, f"{path}.{k}")
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from leaves(v, f"{path}[{i}]")
    elif isinstance(node, str):
        yield path, node


seen = 0
for path, text in leaves(wf):
    seen += 1
    check("secrets." not in text, f"{path}: references a secret; every write uses github.token")
    check(
        not re.search(r"github\.event\.(issue|pull_request)\.(title|body)", text),
        f"{path}: references an issue or PR title or body; the script reads them from the API",
    )
    check(
        not re.search(r"(?<![a-z])(un)?labeled", text),
        f"{path}: handles a label event; label writes must start nothing",
    )
check(seen > 100, f"walked only {seen} keys and strings; the document did not parse as expected")

call = (wf.get("on") or {}).get("workflow_call") or {}
check(isinstance(call, dict) and "inputs" in call, "on.workflow_call.inputs is missing")
check("secrets" not in call, "on.workflow_call declares secrets; this workflow takes none")
ref = ((call.get("inputs") or {}).get("plugins-ref") or {}).get("default", "")
check(re.fullmatch(r"[0-9a-f]{40}", str(ref)) is not None, f"plugins-ref default {ref!r} is not a full commit SHA")

top = wf.get("permissions")
check(
    top == {"contents": "read", "issues": "write", "pull-requests": "write"},
    f"top-level permissions {top!r} differ from the documented caller grant",
)

jobs = wf.get("jobs") or {}
check(len(jobs) > 0, "no jobs")
tokens = writes = creates = gh_steps = 0
for jid, job in jobs.items():
    perms = job.get("permissions")
    check(isinstance(perms, dict), f"job {jid}: no permissions map")
    for scope, level in (perms or {}).items():
        check(
            isinstance(top, dict) and LEVEL.get(level, 9) <= LEVEL.get(top.get(scope)),
            f"job {jid}: asks for {scope}: {level}, more than the caller grant; it would fail at startup",
        )
    check(job.get("runs-on") == "ubuntu-slim", f"job {jid}: runs-on is {job.get('runs-on')!r}")
    check(job.get("timeout-minutes") is not None, f"job {jid}: no timeout-minutes")
    group = str((job.get("concurrency") or {}).get("group", ""))
    check(group.startswith("issue-labels-"), f"job {jid}: concurrency group {group!r} lacks the issue-labels- prefix")
    for k, v in (job.get("env") or {}).items():
        if "TOKEN" in k.upper():
            tokens += 1
            check(v == TOKEN, f"job {jid}: env {k} is {v!r}")
    fetched = False
    for i, step in enumerate(job.get("steps") or []):
        where = f"job {jid} step {step.get('name', i)!r}"
        env = step.get("env") or {}
        for k, v in env.items():
            if "TOKEN" in k.upper():
                tokens += 1
                check(v == TOKEN, f"{where}: env {k} is {v!r}, not {TOKEN}")
        uses = step.get("uses")
        if uses is not None:
            w = step.get("with") or {}
            check(
                re.fullmatch(r"actions/checkout@[0-9a-f]{40}", str(uses)) is not None,
                f"{where}: uses {uses!r}; only a SHA-pinned actions/checkout belongs here",
            )
            check(
                w.get("repository") == "laurigates/claude-plugins",
                f"{where}: checks out {w.get('repository')!r}; the calling repository is never checked out",
            )
            check(w.get("ref") == "${{ inputs.plugins-ref }}", f"{where}: ref is {w.get('ref')!r}")
            check(str(w.get("persist-credentials", "")).lower() == "false", f"{where}: persist-credentials is not false")
            check(w.get("token") in (None, TOKEN), f"{where}: with.token is {w.get('token')!r}")
            fetched = True
            continue
        run = str(step.get("run", ""))
        check(run != "", f"{where}: neither uses: nor run:")
        check("${{" not in run, f"{where}: the run body contains an expression; bind it through env:")
        check(
            not re.search(r"GH_TOKEN=|GITHUB_TOKEN=|GH_ENTERPRISE_TOKEN|gh\s+auth|--with-token", run),
            f"{where}: the run body sets a token itself",
        )
        check(
            not re.search(r"--taxonomy(?!-path)", run),
            f"{where}: reads a taxonomy file from disk; it is read through the contents API",
        )
        if re.search(r"\bgh\s|issue-labels\.py", run):
            gh_steps += 1
            check(env.get("GH_TOKEN") == TOKEN, f"{where}: calls gh or the script without GH_TOKEN: {TOKEN}")
            check(fetched or "issue-labels.py" not in run, f"{where}: runs the script before fetching it")
        for sub in re.findall(r"\bgh\s+(issue|pr|label|repo|release|workflow|run|secret|variable)\s+([a-z-]+)", run):
            check(sub in ALLOWED_GH, f"{where}: runs `gh {sub[0]} {sub[1]}`")
            if sub == ("issue", "create"):
                creates += 1
                check(jid == "sweep", f"{where}: only the sweep job files an issue")
        check("graphql" not in run and "--method" not in run, f"{where}: uses gh api graphql or --method")
        for line in run.splitlines():
            if not re.search(r"\bgh\s+api\b", line):
                continue
            # gh api turns into a POST as soon as it is given fields or input.
            if re.search(r"\s-X\s|\s--input\s|\s-[fF]\s|--field|--raw-field", line):
                writes += 1
                check(
                    ALLOWED_WRITE.search(line) is not None
                    and len(re.findall(r"\s-X\s", line)) == 1
                    and not re.search(r"\s-[fF]\s|--field|--raw-field", line),
                    f"{where}: write call is not a POST to an issue's labels, comments or assignees: {line.strip()}",
                )
check(tokens >= gh_steps > 0, f"{tokens} token binding(s) for {gh_steps} step(s) that call gh or the script")
check(writes > 0, "found no gh api write call; the scan pattern is broken")
check(creates == 1, f"expected one `gh issue create`, found {creates}")
for e in errs:
    print(e)
print(f"COUNT {n} {len(errs)}")
PY
)"
# The python block prints each failed check, then `COUNT <checks> <failed>`. A
# missing COUNT line means it crashed, which must not read as a pass.
count="$(sed -nE 's/^COUNT ([0-9]+) ([0-9]+)$/\1 \2/p' <<<"$static")"
if [ -z "$count" ]; then
  fail "the static check crashed: $static"
else
  read -r n_checks n_failed <<<"$count"
  while IFS= read -r line; do
    case "$line" in COUNT* | '') ;; *) printf '  FAIL [static] %s\n' "$line" ;; esac
  done <<<"$static"
  checks=$((checks + n_checks))
  failures=$((failures + n_failed))
fi
# The caller example in the header is what adopting repos copy.
ok
if grep -nE '^#.*types:.*labeled' "$WF" >/dev/null; then fail "the header's caller example listens for a label event"; fi

# ------------------------------------------------------------ 2. fixtures
# body <job> <step name> <file>: extract one shipped run: body.
body() {
  JOB="$1" STEP="$2" yq -e '.jobs[strenv(JOB)].steps[] | select(.name == strenv(STEP)) | .run' "$WF" >"$3" 2>/dev/null || true
  [ -s "$3" ] || { echo "FATAL: step '$2' not found in job '$1' of $WF" >&2; exit 1; }
}
body classify-issue 'Classify' "$work/classify.sh"
body classify-issue 'Apply labels' "$work/apply.sh"
body classify-pr 'Classify' "$work/classify-pr.sh"
body classify-pr 'Apply labels' "$work/apply-pr.sh"
body classify-pr 'Check the head branch' "$work/gate.sh"
body provision 'Provision labels from the taxonomy' "$work/provision.sh"
body unblock 'Clear the blocked label where every blocker is closed' "$work/unblock.sh"
body sweep 'Audit open issues' "$work/audit.sh"
body sweep 'Report audit findings' "$work/report.sh"
body sweep 'Backfill labels' "$work/backfill.sh"

CASE=shared-bodies
ok; cmp -s "$work/classify.sh" "$work/classify-pr.sh" || fail "Classify differs between classify-issue and classify-pr"
ok; cmp -s "$work/apply.sh" "$work/apply-pr.sh" || fail "Apply labels differs between classify-issue and classify-pr"

mkdir -p "$work/bin" "$work/ws/.issue-labels/git-plugin/scripts" "$work/stub"
cat >"$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
# Stub gh: logs each call, the stdin of a call given `--input -`, and the file
# behind --body-file; answers the reads the steps make.
if [ "${1:-}" = --stub-sentinel ]; then echo STUB_GH_ISSUE_LABELS_WORKFLOW; exit 0; fi
printf '%s\n' "$*" >>"$GH_LOG"
prev=""
for arg in "$@"; do
  if [ "$prev" = --body-file ]; then sed 's/^/BODYFILE /' "$arg" >>"$GH_LOG"; fi
  prev="$arg"
done
case "$*" in *"--input -"*) printf 'STDIN %s\n' "$(cat)" >>"$GH_LOG" ;; esac
case "$*" in
  "issue list "*) printf '%s\n' "${STUB_ISSUE_LIST:-[]}" ;;
  "issue create "*) [ "${STUB_CREATE_FAIL:-0}" = 0 ] || exit 1; echo "https://example.test/o/r/issues/77" ;;
  "label list "*) printf '%s\n' "${STUB_LABELS:-[]}" ;;
  "api --paginate repos/o/r/issues/"*"/comments?per_page=100 "*) printf '%s\n' "${STUB_COMMENTS:-}" ;;
  "api repos/o/r/issues/"*" --jq .body // \"\"") printf '%s\n' "${STUB_ISSUE_BODY:-}" ;;
esac
exit 0
EOF
chmod +x "$work/bin/gh"
# Stand-in for the pinned script: logs its arguments, then prints the canned
# output for the subcommand (per issue when classify-<n>.out exists) and exits
# with the canned status.
cat >"$work/ws/.issue-labels/git-plugin/scripts/issue-labels.py" <<'EOF'
import os, sys

args = sys.argv[1:]
with open(os.environ["PY_LOG"], "a") as log:
    log.write(" ".join(args) + "\n")
stub = os.environ["STUB_DIR"]
name = args[0]
for flag in ("--issue", "--pr"):
    if flag in args:
        per_item = f"{args[0]}-{args[args.index(flag) + 1]}"
        if os.path.exists(os.path.join(stub, per_item + ".out")):
            name = per_item
path = os.path.join(stub, name)
if os.path.exists(path + ".out"):
    with open(path + ".out") as out:
        sys.stdout.write(out.read())
rc = 0
if os.path.exists(path + ".rc"):
    with open(path + ".rc") as fh:
        rc = int(fh.read().strip())
sys.exit(rc)
EOF

CASE=stubs
ok
if [ "$(PATH="$work/bin:$PATH" command -v gh)" != "$work/bin/gh" ] || [ ! -x "$work/bin/gh" ] \
  || [ "$(PATH="$work/bin:$PATH" gh --stub-sentinel 2>/dev/null)" != STUB_GH_ISSUE_LABELS_WORKFLOW ]; then
  echo "FATAL: the stub gh is not the gh on PATH; refusing to run step bodies against the real one" >&2
  exit 1
fi

: >"$work/all-gh.log"
# run <body> [VAR=value ...]: run one extracted body from the scratch workspace
# with a clean environment. Sets RC, OUT, LOG (gh calls), PY (script calls),
# SUMMARY and OUTPUTS.
run() {
  local script="$1"
  shift
  : >"$work/gh.log"
  : >"$work/py.log"
  : >"$work/summary.md"
  : >"$work/outputs.txt"
  rm -rf "$work/tmp"
  mkdir -p "$work/tmp"
  RC=0
  OUT="$(cd "$work/ws" && env -i PATH="$work/bin:$PATH" HOME="$work" GH_LOG="$work/gh.log" PY_LOG="$work/py.log" \
    STUB_DIR="$work/stub" GITHUB_STEP_SUMMARY="$work/summary.md" GITHUB_OUTPUT="$work/outputs.txt" \
    RUNNER_TEMP="$work/tmp" REPO=o/r "$@" bash "$script" 2>&1 </dev/null)" || RC=$?
  LOG="$(cat "$work/gh.log")"
  PY="$(cat "$work/py.log")"
  SUMMARY="$(cat "$work/summary.md")"
  OUTPUTS="$(cat "$work/outputs.txt")"
  cat "$work/gh.log" >>"$work/all-gh.log"
}
# stub_out <name> <rc> <content>: what the stand-in script prints for <name>.
stub_out() { printf '%s\n' "$3" >"$work/stub/$1.out"; printf '%s\n' "$2" >"$work/stub/$1.rc"; }
stub_reset() { rm -rf "$work/stub"; mkdir -p "$work/stub"; }
rc_is() { ok; [ "$RC" -eq "$1" ] || fail "exit $RC, want $1: $OUT"; }
is() { ok; [ "$2" = "$3" ] || fail "$1: wanted '$3', got '$2'"; }
has() { ok; grep -qF -- "$2" <<<"$1" || fail "missing '$2' in: $(tr '\n' ' ' <<<"$1" | cut -c1-400)"; }
lacks() { ok; if grep -qF -- "$2" <<<"$1"; then fail "unexpected '$2' in: $(tr '\n' ' ' <<<"$1" | cut -c1-400)"; fi; }
# Calls that change something on GitHub, as the stub logged them.
write_calls() { grep -cE -- '(^| )-X [A-Z]+|^issue create|^(issue|pr|label) (edit|close|comment|delete|create)' "$work/gh.log" || true; }
no_gh_calls() { ok; [ -z "$LOG" ] || fail "expected no gh call at all, got: $(tr '\n' ' ' <<<"$LOG")"; }
writes_are() { ok; [ "$(write_calls)" -eq "$1" ] || fail "expected $1 write call(s), got $(write_calls): $(tr '\n' ' ' <<<"$LOG")"; }

TAX="$(yq -r '.on.workflow_call.inputs["taxonomy-path"].default' "$WF")"
SKIP_DEFAULT="$(yq -r '.on.workflow_call.inputs["skip-heads"].default' "$WF")"
[ -n "$TAX" ] && [ "$TAX" != null ] || { echo "FATAL: no taxonomy-path default in $WF" >&2; exit 1; }

# ---- Classify
RESULT_OK='{"status": "OK", "number": 7, "kind": "issue", "title_form": "bracket",
 "add": ["bug", "area:ota"],
 "derived": [{"label": "bug", "source": "title:bug"}, {"label": "area:ota", "source": "scope:ota"},
             {"label": "core:ci", "source": "scope:ci"}, {"label": "build:robot", "source": "scope:robot"}],
 "skipped": [{"label": "core:ci", "reason": "prefix_present"}, {"label": "build:robot", "reason": "missing_in_repo"}]}'

CASE=classify-issue
stub_reset
stub_out classify 0 "$RESULT_OK"
run "$work/classify.sh" KIND=issue NUMBER=7 TAXONOMY_PATH="$TAX" RESULT="$work/result.json"
rc_is 0
is "script arguments" "$PY" "classify --repo o/r --issue 7 --taxonomy-path $TAX"
ok; jq -e '.add == ["bug", "area:ota"]' "$work/result.json" >/dev/null 2>&1 || fail "the result file does not hold the script's output"
no_gh_calls

CASE=classify-pr
run "$work/classify.sh" KIND=pr NUMBER=9 TAXONOMY_PATH="$TAX" RESULT="$work/result.json"
rc_is 0
is "script arguments" "$PY" "classify --repo o/r --pr 9 --taxonomy-path $TAX"

CASE=classify-script-error
stub_out classify 1 '{"status": "ERROR", "reason": "taxonomy_invalid: build.x: field '"'"'path'"'"' is not allowed here"}'
run "$work/classify.sh" KIND=issue NUMBER=7 TAXONOMY_PATH="$TAX" RESULT="$work/result.json"
rc_is 1
has "$OUT" 'taxonomy_invalid'

CASE=classify-hostile-number
run "$work/classify.sh" KIND=issue NUMBER='7; touch pwned' TAXONOMY_PATH="$TAX" RESULT="$work/result.json"
rc_is 1
is "script not called" "$PY" ""
ok; [ ! -e "$work/ws/pwned" ] || fail "the number reached a shell"

CASE=classify-bad-kind
run "$work/classify.sh" KIND=fixture NUMBER=7 TAXONOMY_PATH="$TAX" RESULT="$work/result.json"
rc_is 1
is "script not called" "$PY" ""

# ---- Apply labels
apply() { # <result content> [VAR=value ...]
  printf '%s\n' "$1" >"$work/result.json"
  shift
  run "$work/apply.sh" NUMBER=7 RESULT="$work/result.json" "$@"
}

CASE=apply-dry-run
apply "$RESULT_OK" DRY_RUN=true
rc_is 0
no_gh_calls
has "$OUT" 'would add to #7'
has "$OUT" 'area:ota'
has "$SUMMARY" 'Dry run'

# A step writes only on the exact value `false`: anything else is a dry run.
for value in '' TRUE 1 no False; do
  CASE="apply-dry-run-value=[$value]"
  apply "$RESULT_OK" DRY_RUN="$value"
  rc_is 0
  no_gh_calls
done
CASE=apply-dry-run-unset
apply "$RESULT_OK"
rc_is 0
no_gh_calls

CASE=apply-normal
apply "$RESULT_OK" DRY_RUN=false
rc_is 0
is "gh calls" "$LOG" 'api -X POST repos/o/r/issues/7/labels --input - --silent
STDIN {"labels":["bug","area:ota"]}'
lacks "$LOG" 'core:ci'
lacks "$LOG" 'build:robot'
has "$SUMMARY" 'Added to #7'

CASE=apply-nothing-to-add
apply '{"status": "OK", "add": [], "derived": [{"label": "bug", "source": "title:bug"}], "skipped": [{"label": "bug", "reason": "already_set"}]}' DRY_RUN=false
rc_is 0
no_gh_calls

for bad in \
  '{"status": "ERROR", "reason": "gh api failed"}' \
  '{"status": "ERROR", "add": ["bug"]}' \
  '{"status": "OK", "add": "bug"}' \
  '{"status": "OK", "add": ["bug", {"label": "area:ota"}]}' \
  '{"status": "OK"}' \
  'not json' \
  ''; do
  CASE="apply-malformed=[$bad]"
  apply "$bad" DRY_RUN=false
  rc_is 1
  no_gh_calls
done
CASE=apply-missing-result
run "$work/apply.sh" NUMBER=7 RESULT="$work/absent.json" DRY_RUN=false
rc_is 1
no_gh_calls

# ---- Check the head branch
gate() { # <head> <skip-heads>; sets GATE
  run "$work/gate.sh" HEAD_REF="$1" SKIP_HEADS="$2"
  GATE="$(sed -n 's/^run=//p' <<<"$OUTPUTS")"
}
CASE=gate-default-skips-release-please
gate 'release-please--branches--main' "$SKIP_DEFAULT"
rc_is 0; is "run" "$GATE" false
CASE=gate-feature-branch-runs
gate 'feat/issue-labels' "$SKIP_DEFAULT"
rc_is 0; is "run" "$GATE" true
CASE=gate-empty-input-runs
gate 'release-please--branches--main' ''
rc_is 0; is "run" "$GATE" true
CASE=gate-comma-list
gate 'renovate/actions' 'release-please--*, renovate/*'
rc_is 0; is "run" "$GATE" false
CASE=gate-newline-list
gate 'renovate/actions' 'release-please--*
# bots
renovate/*'
rc_is 0; is "run" "$GATE" false
# The head is matched against the patterns, never used as one, and never run.
CASE=gate-hostile-head
gate '*' "$SKIP_DEFAULT"
rc_is 0; is "run" "$GATE" true
gate '$(touch pwned)`touch pwned`' "$SKIP_DEFAULT"
rc_is 0; is "run" "$GATE" true
ok; [ ! -e "$work/ws/pwned" ] || fail "the head branch name was executed"
lacks "$OUT" 'pwned'

# ---- Provision
PROVISION_OK='=== ISSUE LABELS PROVISION ===
REPO=o/r
DRY_RUN=false
CREATE=1
UPDATE=0
RENAME=0
UNCHANGED=2
APPLIED=1
ACTIONS:
  - OP=create LABEL=build:robot
STATUS=OK
ISSUE_COUNT=0
=== END ISSUE LABELS PROVISION ==='
provision() { run "$work/provision.sh" TAXONOMY_PATH="$TAX" RESULT="$work/tmp-provision.txt" "$@"; }

CASE=provision-normal
stub_reset
stub_out provision 0 "$PROVISION_OK"
provision DRY_RUN=false
rc_is 0
is "script arguments" "$PY" "provision --repo o/r --taxonomy-path $TAX"
has "$SUMMARY" 'OP=create LABEL=build:robot'
CASE=provision-dry-run
provision DRY_RUN=true
rc_is 0
is "script arguments" "$PY" "provision --repo o/r --taxonomy-path $TAX --dry-run"
CASE=provision-dry-run-unset
provision
is "script arguments" "$PY" "provision --repo o/r --taxonomy-path $TAX --dry-run"

CASE=provision-no-taxonomy
stub_out provision 1 "=== ISSUE LABELS PROVISION ===
STATUS=ERROR
REASON=taxonomy_missing: $TAX is empty or absent
ISSUE_COUNT=1
=== END ISSUE LABELS PROVISION ==="
provision DRY_RUN=false
rc_is 0
has "$OUT" '::notice title=Issue labels::no label taxonomy'

CASE=provision-invalid-taxonomy
stub_out provision 1 '=== ISSUE LABELS PROVISION ===
REPO=o/r
DRY_RUN=false
APPLIED=0
STATUS=ERROR
REASON=taxonomy_invalid: build.robot.color is required to provision the label
ISSUE_COUNT=1
=== END ISSUE LABELS PROVISION ==='
provision DRY_RUN=false
rc_is 1
lacks "$OUT" '::notice'

# ---- Unblock
unblock() { run "$work/unblock.sh" NUMBER=12 RESULT="$work/tmp-unblock.txt" "$@"; }
CASE=unblock-normal
stub_reset
stub_out unblock 0 '=== ISSUE LABELS UNBLOCK ===
REPO=o/r
ISSUE=12
UNBLOCKED=1
STATUS=OK
=== END ISSUE LABELS UNBLOCK ==='
unblock DRY_RUN=false
rc_is 0
is "script arguments" "$PY" "unblock --repo o/r --issue 12"
has "$SUMMARY" 'UNBLOCKED=1'
CASE=unblock-dry-run
unblock DRY_RUN=true
is "script arguments" "$PY" "unblock --repo o/r --issue 12 --dry-run"
CASE=unblock-dry-run-unset
unblock
is "script arguments" "$PY" "unblock --repo o/r --issue 12 --dry-run"
CASE=unblock-script-error
stub_out unblock 1 'STATUS=ERROR'
unblock DRY_RUN=false
rc_is 1

# ---- Sweep: audit
AUDIT='{"status": "WARN", "repo": "o/r", "open_issues": 12,
 "counts": {"missing_type": 2, "missing_routing": 2, "blocked_no_link": 1, "blocked_resolved": 0,
            "open_link_not_blocked": 0, "needs_stale": 0},
 "findings": [{"type": "missing_type", "number": 3, "msg": "no type label (bug, enhancement)"},
              {"type": "missing_type", "number": 5, "msg": "no type label (bug, enhancement)"},
              {"type": "missing_routing", "number": 5, "msg": "no build: / area: / core: label"},
              {"type": "missing_routing", "number": 9, "msg": "no build: / area: / core: label"},
              {"type": "blocked_no_link", "number": 8, "msg": "'"'"'blocked'"'"' with no blocked_by link"}]}'
AUDIT_CLEAN='{"status": "OK", "repo": "o/r", "open_issues": 12,
 "counts": {"missing_type": 0, "missing_routing": 0, "blocked_no_link": 0, "blocked_resolved": 0,
            "open_link_not_blocked": 0, "needs_stale": 0},
 "findings": []}'

CASE=audit-step
stub_reset
stub_out audit 0 "$AUDIT"
run "$work/audit.sh" MODE=audit NEEDS_STALE_DAYS=30 AUDIT="$work/audit.json"
rc_is 0
is "script arguments" "$PY" "audit --repo o/r --needs-stale-days 30 --json"
has "$OUT" 'missing_type: 2'
CASE=audit-bad-mode
run "$work/audit.sh" MODE='backfill; touch pwned' NEEDS_STALE_DAYS=30 AUDIT="$work/audit.json"
rc_is 1
is "script not called" "$PY" ""
CASE=audit-script-error
stub_out audit 1 '{"status": "ERROR", "reason": "gh api failed"}'
run "$work/audit.sh" MODE=backfill NEEDS_STALE_DAYS=30 AUDIT="$work/audit.json"
rc_is 1

# ---- Sweep: report
report() { # <audit content> [VAR=value ...]
  printf '%s\n' "$1" >"$work/audit.json"
  shift
  run "$work/report.sh" AUDIT="$work/audit.json" SERVER_URL=https://example.test RUN_ID=99 NEEDS_STALE_DAYS=30 \
    AUDIT_TITLE='Issue label audit' AUDIT_LABELS='chore, core:quality' ASSIGNEE=o "$@"
}
LABELS_CHORE_ONLY='[{"name": "bug"}, {"name": "Chore"}]'

CASE=report-clean
report "$AUDIT_CLEAN" DRY_RUN=false
rc_is 0
no_gh_calls
has "$SUMMARY" '12 open issue(s), 0 finding(s)'

CASE=report-dry-run
report "$AUDIT" DRY_RUN=true
rc_is 0
writes_are 0
has "$OUT" "would file an issue titled 'Issue label audit'"
has "$SUMMARY" '[#8](https://example.test/o/r/issues/8)'
CASE=report-dry-run-unset
report "$AUDIT"
rc_is 0
writes_are 0

CASE=report-files-issue
report "$AUDIT" DRY_RUN=false STUB_LABELS="$LABELS_CHORE_ONLY"
rc_is 0
has "$LOG" 'issue create --repo o/r --title Issue label audit --body-file'
has "$LOG" 'BODYFILE #8  blocked_no_link'
has "$LOG" 'api -X POST repos/o/r/issues/77/labels --input - --silent'
has "$LOG" 'STDIN {"labels":["chore"]}'
lacks "$LOG" 'core:quality'
has "$LOG" 'api -X POST repos/o/r/issues/77/assignees --input - --silent'
has "$LOG" 'STDIN {"assignees":["o"]}'
writes_are 3
# The report must not link the listed issues: each link would add a
# cross-reference to that issue's timeline on every report.
lacks "$LOG" '/issues/8'
MARKER="$(sed -nE 's/^BODYFILE <!-- (issue-labels-audit: [0-9a-f]{12}) -->$/\1/p' <<<"$LOG")"
ok; [ -n "$MARKER" ] || fail "the filed body carries no findings marker"

CASE=report-no-audit-labels-in-repo
report "$AUDIT" DRY_RUN=false STUB_LABELS='[{"name": "bug"}]'
rc_is 0
lacks "$LOG" '/labels --input'
writes_are 2

CASE=report-existing-unchanged
report "$AUDIT" DRY_RUN=false STUB_ISSUE_LIST='[{"number": 40, "title": "Issue label audit"}, {"number": 41, "title": "Issue label audit (old)"}]' \
  STUB_ISSUE_BODY="first report <!-- issue-labels-audit: 000000000000 -->" STUB_COMMENTS="later report <!-- $MARKER -->"
rc_is 0
writes_are 0
has "$OUT" 'nothing posted'

CASE=report-existing-changed
report "$AUDIT" DRY_RUN=false STUB_ISSUE_LIST='[{"number": 40, "title": "Issue label audit"}]' \
  STUB_ISSUE_BODY="first report <!-- $MARKER -->" STUB_COMMENTS="later report <!-- issue-labels-audit: 000000000000 -->"
rc_is 0
writes_are 1
has "$LOG" 'api -X POST repos/o/r/issues/40/comments --input - --jq .html_url'
lacks "$LOG" 'issue create'

CASE=report-existing-dry-run
report "$AUDIT" DRY_RUN=true STUB_ISSUE_LIST='[{"number": 40, "title": "Issue label audit"}]'
rc_is 0
writes_are 0
has "$OUT" 'would comment on #40'

CASE=report-create-fails
report "$AUDIT" DRY_RUN=false STUB_CREATE_FAIL=1
rc_is 1
lacks "$LOG" '/labels --input'

CASE=report-malformed-audit
report '{"status": "ERROR", "reason": "gh api failed"}' DRY_RUN=false
rc_is 1
no_gh_calls

# ---- Sweep: backfill
backfill() { # [VAR=value ...]
  printf '%s\n' "$AUDIT" >"$work/audit.json"
  run "$work/backfill.sh" AUDIT="$work/audit.json" SERVER_URL=https://example.test TAXONOMY_PATH="$TAX" "$@"
}
stub_reset
stub_out classify-3 0 '{"status": "OK", "number": 3, "add": ["bug"], "derived": [], "skipped": []}'
stub_out classify-5 0 '{"status": "OK", "number": 5, "add": [], "derived": [], "skipped": []}'
stub_out classify-9 0 '{"status": "OK", "number": 9, "add": ["core:ci"], "derived": [{"label": "needs:hardware", "source": "x"}], "skipped": []}'

CASE=backfill-normal
backfill DRY_RUN=false MAX_ISSUES=25
rc_is 0
is "script calls" "$PY" "classify --repo o/r --issue 3 --taxonomy-path $TAX
classify --repo o/r --issue 5 --taxonomy-path $TAX
classify --repo o/r --issue 9 --taxonomy-path $TAX"
is "gh calls" "$LOG" 'api -X POST repos/o/r/issues/3/labels --input - --silent
STDIN {"labels":["bug"]}
api -X POST repos/o/r/issues/9/labels --input - --silent
STDIN {"labels":["core:ci"]}'
has "$SUMMARY" '3 candidate(s) lack a type or routing label; 3 classified (max-issues: 25); 2 with labels to add.'

CASE=backfill-capped
backfill DRY_RUN=false MAX_ISSUES=2
rc_is 0
is "script calls" "$PY" "classify --repo o/r --issue 3 --taxonomy-path $TAX
classify --repo o/r --issue 5 --taxonomy-path $TAX"
writes_are 1
lacks "$LOG" 'issues/9/'

CASE=backfill-dry-run
backfill DRY_RUN=true MAX_ISSUES=25
rc_is 0
no_gh_calls
has "$OUT" '#9: would add `core:ci`'
has "$SUMMARY" 'Dry run: nothing was written.'
CASE=backfill-dry-run-unset
backfill MAX_ISSUES=25
rc_is 0
no_gh_calls

CASE=backfill-classify-fails
stub_out classify-5 1 '{"status": "ERROR", "reason": "gh api failed"}'
backfill DRY_RUN=false MAX_ISSUES=25
rc_is 1
lacks "$LOG" 'issues/9/'
lacks "$LOG" 'issues/5/'

CASE=backfill-bad-max
backfill DRY_RUN=false MAX_ISSUES='2; touch pwned'
rc_is 1
is "script not called" "$PY" ""

# ---- Across every case: the stand-in ran, and nothing was ever edited.
CASE=all-cases
ok; [ -s "$work/all-gh.log" ] || fail "the stub gh logged nothing in any case"
ok
if grep -nE -- '-X (PATCH|PUT|DELETE)|^(issue|pr) edit|title=|body=' "$work/all-gh.log" >/dev/null; then
  fail "a step edited or deleted something: $(grep -nE -- '-X (PATCH|PUT|DELETE)|^(issue|pr) edit|title=|body=' "$work/all-gh.log" | head -n 3 | tr '\n' ' ')"
fi

if [ "$failures" -ne 0 ]; then
  printf '%s: %d failure(s) in %d assertion(s)\n' "$NAME" "$failures" "$checks"
  exit 1
fi
printf 'PASS: %s (%d assertion(s))\n' "$NAME" "$checks"

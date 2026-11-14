#!/usr/bin/env bash
# Tests for reusable-issue-labels.yml.
#
# Part 1 reads the parsed workflow (yq, so comments are gone) and checks what
# keeps it from looping or leaking: every token is `github.token`, no `run:`
# body contains an expression, no issue or PR title or body is referenced
# anywhere, nothing handles a label event, every write call is a POST to an
# issue's labels, comments or assignees (never an edit), every job runs the
# pinned script and never checks out the calling repository, and no job asks
# for more than the documented caller grant. The write-call scan joins
# backslash-newline continuations first.
#
# Part 1b evaluates the shipped job `if:`, step `if:` and concurrency group
# expressions over a matrix of event contexts: which job runs for each event
# (bot edits, forks, Dependabot, pr-labels, the default branch), that every
# classify-pr step after the gate is skipped with it, and that the concurrency
# groups separate repositories, issues and PRs.
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
# findings change, only an audit issue github-actions[bot] opened is adopted,
# a failed label listing still assigns the new issue, a repository with no
# taxonomy file (a 404) gets the report it would get without missing_routing
# findings while backfill still classifies those issues, any other failed
# taxonomy read fails the report step, and backfill stops at max-issues.
# Bodies run under `bash -e`, as Actions runs them.
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


def scan_writes(run):
    """(write calls, offending lines) among the `gh api` calls in a run body.

    Backslash-newline continuations are joined first, so a call split over
    several lines is read as the one command bash runs.
    """
    count, bad = 0, []
    for line in re.sub(r"\\\n[ \t]*", " ", run).splitlines():
        if not re.search(r"\bgh\s+api\b", line):
            continue
        # gh api turns into a POST as soon as it is given fields or input.
        if re.search(r"\s-X\s|\s--input\s|\s-[fF]\s|--field|--raw-field", line):
            count += 1
            if not (
                ALLOWED_WRITE.search(line) is not None
                and len(re.findall(r"\s-X\s", line)) == 1
                and not re.search(r"\s-[fF]\s|--field|--raw-field", line)
            ):
                bad.append(line.strip())
    return count, bad


# The scanner itself, on bodies whose verdict is known.
for body, want in (
    ('gh api \\\n  -X DELETE "repos/$REPO/issues/$N/labels/blocked"\n', (1, 1)),
    ('gh api -X DELETE "repos/$REPO/issues/$N/labels/blocked"\n', (1, 1)),
    ('jq -c . "$f" | gh api \\\n    -X POST "repos/$REPO/issues/$N/labels" --input - --silent\n', (1, 0)),
    ('gh api "repos/$REPO/issues/$N" --jq .body\n', (0, 0)),
):
    got = scan_writes(body)
    check((got[0], len(got[1])) == want, f"scan_writes({body!r}) gave {got}, want {want} (calls, offending)")


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
        n_writes, bad = scan_writes(run)
        writes += n_writes
        check(not bad, f"{where}: write call is not a POST to an issue's labels, comments or assignees: {bad}")
check(tokens >= gh_steps > 0, f"{tokens} token binding(s) for {gh_steps} step(s) that call gh or the script")
check(writes > 0, "found no gh api write call; the scan pattern is broken")
check(creates == 1, f"expected one `gh issue create`, found {creates}")
for e in errs:
    print(e)
print(f"COUNT {n} {len(errs)}")
PY
)"
# absorb <output>: a python block prints each failed check, then
# `COUNT <checks> <failed>`. A missing COUNT line means it crashed, which must
# not read as a pass.
absorb() {
  local count n_checks n_failed line
  count="$(sed -nE 's/^COUNT ([0-9]+) ([0-9]+)$/\1 \2/p' <<<"$1")"
  if [ -z "$count" ]; then
    fail "the python check crashed: $1"
    return
  fi
  read -r n_checks n_failed <<<"$count"
  while IFS= read -r line; do
    case "$line" in COUNT* | '') ;; *) printf '  FAIL [%s] %s\n' "$CASE" "$line" ;; esac
  done <<<"$1"
  checks=$((checks + n_checks))
  failures=$((failures + n_failed))
}
absorb "$static"

# ------------------------------------------------------------ 1b. conditions
# Evaluates the shipped job `if:`, step `if:` and concurrency group
# expressions with a small evaluator for the expression syntax they use, over
# event contexts built here. The expressions are read from the parsed
# workflow and never retyped, so these cases pin what each one decides.
CASE=conditions
conditions="$(python3 - "$work/doc.json" 2>&1 <<'PY' || true
import copy, json, math, re, sys

with open(sys.argv[1]) as fh:
    wf = json.load(fh) or {}
errs, n = [], 0


def check(cond, msg):
    global n
    n += 1
    if not cond:
        errs.append(msg)


# ---- evaluator: literals, context paths, == != < <= > >=, ! && ||, ( ),
# contains, startsWith, endsWith, fromJSON, format. Anything else raises, so
# a new construct crashes the block (no COUNT line) instead of passing.
TOKEN = re.compile(
    r"\s*(?:(?P<str>'(?:[^']|'')*')|(?P<num>-?\d+(?:\.\d+)?)|(?P<op>==|!=|<=|>=|&&|\|\||[!<>(),])"
    r"|(?P<id>[A-Za-z_][A-Za-z0-9_-]*(?:\.[A-Za-z_][A-Za-z0-9_-]*)*))"
)


def tokenize(src):
    out, i = [], 0
    src = src.strip()
    while i < len(src):
        m = TOKEN.match(src, i)
        if not m or m.end() == i:
            raise ValueError(f"cannot tokenize {src[i:]!r}")
        i = m.end()
        kind = m.lastgroup
        out.append((kind, m.group(kind)))
    return out


def num(v):
    if v is None:
        return 0.0
    if isinstance(v, bool):
        return float(v)
    if isinstance(v, (int, float)):
        return float(v)
    if isinstance(v, str):
        try:
            return float(v) if v.strip() else 0.0
        except ValueError:
            return math.nan
    return math.nan


def eq(a, b):
    if isinstance(a, str) and isinstance(b, str):
        return a.casefold() == b.casefold()
    if type(a) is type(b) or (a is None and b is None):
        return a == b
    return num(a) == num(b)


def truthy(v):
    return not (v is None or v is False or v == 0 or v == "")


def text(v):
    if v is None:
        return ""
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, float) and v.is_integer():
        return str(int(v))
    return str(v)


def lookup(ctx, path):
    node = ctx
    for part in path.split("."):
        if not isinstance(node, dict):
            return None
        node = node.get(part)
    return node


FUNCS = {
    "contains": lambda s, x: any(eq(i, x) for i in s) if isinstance(s, list) else text(x).casefold() in text(s).casefold(),
    "startswith": lambda s, x: text(s).casefold().startswith(text(x).casefold()),
    "endswith": lambda s, x: text(s).casefold().endswith(text(x).casefold()),
    "fromjson": lambda s: json.loads(s),
    "format": lambda f, *a: re.sub(r"\{(\d+)\}", lambda m: text(a[int(m.group(1))]), f),
}


def evaluate(src, ctx):
    src = src.strip()
    m = re.fullmatch(r"\$\{\{(.*)\}\}", src, re.S)
    if m:
        src = m.group(1)
    toks = tokenize(src)
    pos = 0

    def peek():
        return toks[pos] if pos < len(toks) else (None, None)

    def take(want=None):
        nonlocal pos
        tok = peek()
        if want is not None and tok[1] != want:
            raise ValueError(f"expected {want!r}, got {tok!r} in {src!r}")
        pos += 1
        return tok

    def p_or():
        v = p_and()
        while peek()[1] == "||":
            take()
            r = p_and()
            v = v if truthy(v) else r
        return v

    def p_and():
        v = p_not()
        while peek()[1] == "&&":
            take()
            r = p_not()
            v = r if truthy(v) else v
        return v

    def p_not():
        if peek()[1] == "!":
            take()
            return not truthy(p_not())
        return p_cmp()

    def p_cmp():
        v = p_primary()
        op = peek()[1]
        if op in ("==", "!=", "<", "<=", ">", ">="):
            take()
            r = p_primary()
            if op == "==":
                return eq(v, r)
            if op == "!=":
                return not eq(v, r)
            a, b = num(v), num(r)
            return {"<": a < b, "<=": a <= b, ">": a > b, ">=": a >= b}[op]
        return v

    def p_primary():
        kind, val = take()
        if kind == "str":
            return val[1:-1].replace("''", "'")
        if kind == "num":
            return float(val)
        if val == "(":
            v = p_or()
            take(")")
            return v
        if kind == "id":
            if val in ("true", "false"):
                return val == "true"
            if val == "null":
                return None
            if peek()[1] == "(":
                fn = FUNCS.get(val.lower())
                if fn is None:
                    raise ValueError(f"unsupported function {val} in {src!r}")
                take("(")
                args = []
                if peek()[1] != ")":
                    args.append(p_or())
                    while peek()[1] == ",":
                        take()
                        args.append(p_or())
                take(")")
                return fn(*args)
            return lookup(ctx, val)
        raise ValueError(f"unexpected token {val!r} in {src!r}")

    v = p_or()
    if pos != len(toks):
        raise ValueError(f"trailing tokens in {src!r}")
    return v


def interpolate(s, ctx):
    return re.sub(r"\$\{\{(.*?)\}\}", lambda m: text(evaluate(m.group(1), ctx)), s)


# ---- contexts
call_inputs = ((wf.get("on") or {}).get("workflow_call") or {}).get("inputs") or {}
DEFAULT_INPUTS = {k: v.get("default") for k, v in call_inputs.items()}


def context(event_name, action=None, **over):
    ctx = {
        "github": {
            "event_name": event_name,
            "repository": "o/r",
            "ref": "refs/heads/main",
            "actor": "alice",
            "event": {
                "action": action,
                "repository": {"default_branch": "main"},
                "sender": {"login": "alice", "type": "User"},
                "issue": {"number": 7, "user": {"login": "alice", "type": "User"}},
                "pull_request": {
                    "number": 9,
                    "user": {"login": "alice", "type": "User"},
                    "head": {"ref": "feat/x", "repo": {"full_name": "o/r"}},
                },
            },
        },
        "inputs": dict(DEFAULT_INPUTS),
        "steps": {},
    }
    for path, value in over.items():
        node = ctx
        parts = path.split("__")
        for part in parts[:-1]:
            node = node.setdefault(part, {})
        node[parts[-1]] = value
    return ctx


jobs = wf.get("jobs") or {}
KNOWN = {"provision", "classify-issue", "classify-pr", "unblock", "sweep"}
check(set(jobs) == KNOWN, f"jobs {sorted(jobs)} differ from {sorted(KNOWN)}; add the new job's cases here")


def running(ctx):
    return {jid for jid, job in jobs.items() if "if" not in job or truthy(evaluate(str(job["if"]), ctx))}


G = "github__event__"
CASES = [
    ("push to the default branch", context("push"), {"provision"}),
    ("push to another branch", context("push", github__ref="refs/heads/feat/x"), set()),
    ("push to main where the default is trunk", context("push", **{G + "repository__default_branch": "trunk"}), set()),
    ("push to trunk, the default", context("push", github__ref="refs/heads/trunk", **{G + "repository__default_branch": "trunk"}), {"provision"}),
    ("issue opened", context("issues", "opened"), {"classify-issue"}),
    ("issue reopened", context("issues", "reopened"), {"classify-issue"}),
    ("issue opened by a bot app", context("issues", "opened", **{G + "sender__type": "Bot"}), {"classify-issue"}),
    ("issue edited by a person", context("issues", "edited"), {"classify-issue"}),
    ("issue edited by a bot", context("issues", "edited", **{G + "sender__type": "Bot"}), set()),
    ("a bot's issue retitled by a person", context("issues", "edited", **{G + "issue__user__type": "Bot"}), {"classify-issue"}),
    ("a person's issue edited by a bot", context("issues", "edited", **{G + "sender__type": "Bot", G + "issue__user__type": "User"}), set()),
    ("issue closed", context("issues", "closed"), {"unblock"}),
    ("issue labeled", context("issues", "labeled"), set()),
    ("issue unlabeled", context("issues", "unlabeled"), set()),
    ("PR opened", context("pull_request", "opened"), {"classify-pr"}),
    ("PR synchronize", context("pull_request", "synchronize"), {"classify-pr"}),
    ("PR reopened", context("pull_request", "reopened"), {"classify-pr"}),
    ("PR edited", context("pull_request", "edited"), {"classify-pr"}),
    ("PR labeled", context("pull_request", "labeled"), set()),
    ("PR closed", context("pull_request", "closed"), set()),
    ("fork PR", context("pull_request", "opened", **{G + "pull_request__head__repo__full_name": "fork/r"}), set()),
    ("fork PR edited", context("pull_request", "edited", **{G + "pull_request__head__repo__full_name": "fork/r"}), set()),
    ("PR event from dependabot", context("pull_request", "synchronize", github__actor="dependabot[bot]"), set()),
    ("dependabot's PR pushed by a person", context("pull_request", "synchronize", **{G + "pull_request__user__login": "dependabot[bot]"}), set()),
    ("pr-labels false", context("pull_request", "opened", **{"inputs__pr-labels": False}), set()),
    ("pull_request_target", context("pull_request_target", "opened"), set()),
    ("schedule", context("schedule"), {"sweep"}),
    ("workflow_dispatch", context("workflow_dispatch"), {"sweep"}),
]
for name, ctx, want in CASES:
    got = running(ctx)
    check(got == want, f"{name}: jobs {sorted(got)} run, want {sorted(want)}")

# ---- step conditions
steps = {jid: job.get("steps") or [] for jid, job in jobs.items()}
gated = [s for s in steps.get("classify-pr", []) if s.get("id") != "gate"]
check(len(gated) >= 3, f"classify-pr has {len(gated)} steps after the gate")
check(any(s.get("id") == "gate" for s in steps.get("classify-pr", [])), "classify-pr has no step with id gate")
for s in gated:
    cond = s.get("if")
    where = f"classify-pr step {s.get('name')!r}"
    check(cond is not None, f"{where}: no if:, so it runs when the head branch is skipped")
    if cond is None:
        continue
    for run_value, want in (("true", True), ("false", False), (None, False)):
        ctx = context("pull_request", "opened", steps={"gate": {"outputs": {"run": run_value}}})
        check(truthy(evaluate(str(cond), ctx)) == want, f"{where}: with the gate at {run_value!r} it decides {not want}")
by_name = {s.get("name"): s for s in steps.get("sweep", [])}
for mode, want in (("audit", "Report audit findings"), ("backfill", "Backfill labels")):
    ctx = context("workflow_dispatch", inputs__mode=mode)
    ran = {name for name, s in by_name.items() if "if" not in s or truthy(evaluate(str(s["if"]), ctx))}
    check(ran == {"Fetch the labelling script", "Audit open issues", want}, f"sweep with mode {mode}: steps {sorted(ran)} run")

# ---- concurrency
# A newer run of classify-pr classifies the same PR again, so the older one may
# be cancelled. Every other job's pending run carries work the next one does
# not repeat (another issue's edit, an unblock, a provision), so none cancels.
for jid, job in jobs.items():
    conc = job.get("concurrency") or {}
    check(conc.get("cancel-in-progress") is (jid == "classify-pr"),
          f"job {jid}: cancel-in-progress is {conc.get('cancel-in-progress')!r}")


def group(jid, ctx):
    return interpolate(str((jobs[jid].get("concurrency") or {}).get("group", "")), ctx)


EVENT = {"provision": ("push", None), "classify-issue": ("issues", "edited"), "classify-pr": ("pull_request", "edited"),
         "unblock": ("issues", "closed"), "sweep": ("schedule", None)}
for jid, (ev, action) in EVENT.items():
    if jid not in jobs:
        continue
    a, b = group(jid, context(ev, action)), group(jid, context(ev, action, github__repository="o/s"))
    check(a != b, f"job {jid}: the concurrency group {a!r} is shared across repositories")
    check(a == group(jid, context(ev, action)), f"job {jid}: the concurrency group is not stable")
for jid, field in (("classify-issue", "issue"), ("unblock", "issue"), ("classify-pr", "pull_request")):
    if jid not in jobs:
        continue
    ev, action = EVENT[jid]
    a = group(jid, context(ev, action))
    b = group(jid, context(ev, action, **{G + field + "__number": 8 if field == "issue" else 10}))
    check(a != b, f"job {jid}: two {field} numbers share the concurrency group {a!r}")
same = context("issues", "closed")
groups = {jid: group(jid, same) for jid in jobs}
check(len(set(groups.values())) == len(groups), f"two jobs share a concurrency group for one event: {groups}")

for e in errs:
    print(e)
print(f"COUNT {n} {len(errs)}")
PY
)"
absorb "$conditions"
CASE=static
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
  "issue list "*)
    # STUB_ISSUE_LIST_AFTER_CREATE: the listing once an `issue create` has run.
    if [ -n "${STUB_ISSUE_LIST_AFTER_CREATE:-}" ] && grep -q '^issue create ' "$GH_LOG"; then
      printf '%s\n' "$STUB_ISSUE_LIST_AFTER_CREATE"
    else
      printf '%s\n' "${STUB_ISSUE_LIST:-[]}"
    fi
    ;;
  "issue create "*) [ "${STUB_CREATE_FAIL:-0}" = 0 ] || exit 1; echo "https://example.test/o/r/issues/77" ;;
  "label list "*) [ "${STUB_LABEL_LIST_FAIL:-0}" = 0 ] || exit 1; printf '%s\n' "${STUB_LABELS:-[]}" ;;
  "api --paginate repos/o/r/issues/"*"/comments?per_page=100 "*) printf '%s\n' "${STUB_COMMENTS:-}" ;;
  "api repos/o/r/issues/"*" --jq .body // \"\"") printf '%s\n' "${STUB_ISSUE_BODY:-}" ;;
  # STUB_TAXONOMY: present (default), absent (the 404 gh prints, as in
  # cli/cli pkg/cmd/api/api.go: "gh: <message> (HTTP <code>)"), or error.
  "api repos/o/r/contents/"*)
    case "${STUB_TAXONOMY:-present}" in
      present) ;;
      absent) echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
      *) echo 'gh: Server Error (HTTP 502)' >&2; exit 1 ;;
    esac
    ;;
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
# SUMMARY and OUTPUTS. `bash -e` is how Actions runs a `run:` step with no
# `shell:` (workflow syntax, defaults.run.shell: unspecified is `bash -e {0}`);
# this workflow sets no shell, so a body's own `set -uo pipefail` still runs
# under -e.
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
    RUNNER_TEMP="$work/tmp" REPO=o/r "$@" bash -e "$script" 2>&1 </dev/null)" || RC=$?
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
    AUDIT_TITLE='Issue label audit' AUDIT_LABELS='chore, core:quality' ASSIGNEE=o TAXONOMY_PATH="$TAX" "$@"
  cp "$work/audit.json" "$work/audit-after-report.json"
}
# AUDIT without its missing_routing findings, as a with-taxonomy run would see
# a repository whose issues all carry a routing label.
AUDIT_NO_ROUTING="$(jq -c '.findings |= map(select(.type != "missing_routing")) | .counts.missing_routing = 0' <<<"$AUDIT")"
AUDIT_ONLY_ROUTING="$(jq -c '.findings |= map(select(.type == "missing_routing"))
  | .counts |= with_entries(.value = (if .key == "missing_routing" then 2 else 0 end))' <<<"$AUDIT")"
TAX_READ="api repos/o/r/contents/$TAX --silent"
bodyfile() { sed -n 's/^BODYFILE //p' <<<"$LOG"; }
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
# With a taxonomy file, missing_routing findings are reported as before.
has "$LOG" "$TAX_READ"
has "$LOG" 'BODYFILE #9  missing_routing'
has "$LOG" 'BODYFILE | `missing_routing` | 2 |'
has "$SUMMARY" '[#9](https://example.test/o/r/issues/9) | `missing_routing`'
lacks "$SUMMARY" 'no taxonomy file'

CASE=report-no-audit-labels-in-repo
report "$AUDIT" DRY_RUN=false STUB_LABELS='[{"name": "bug"}]'
rc_is 0
lacks "$LOG" '/labels --input'
writes_are 2

# `gh issue list --json author` gives an issue filed with GITHUB_TOKEN the
# login `app/github-actions` (read from laurigates/repos-claude-config #150).
BOT='{"login": "app/github-actions", "is_bot": true}'
HUMAN='{"login": "mallory", "is_bot": false}'
OURS_40="[{\"number\": 40, \"title\": \"Issue label audit\", \"author\": $BOT}]"

CASE=report-existing-unchanged
report "$AUDIT" DRY_RUN=false \
  STUB_ISSUE_LIST="[{\"number\": 40, \"title\": \"Issue label audit\", \"author\": $BOT}, {\"number\": 41, \"title\": \"Issue label audit (old)\", \"author\": $BOT}]" \
  STUB_ISSUE_BODY="first report <!-- issue-labels-audit: 000000000000 -->" STUB_COMMENTS="later report <!-- $MARKER -->"
rc_is 0
writes_are 0
has "$OUT" 'nothing posted'
has "$LOG" 'issue list --repo o/r --state open --limit 1000 --json number,title,author'

CASE=report-existing-changed
report "$AUDIT" DRY_RUN=false STUB_ISSUE_LIST="$OURS_40" \
  STUB_ISSUE_BODY="first report <!-- $MARKER -->" STUB_COMMENTS="later report <!-- issue-labels-audit: 000000000000 -->"
rc_is 0
writes_are 1
has "$LOG" 'api -X POST repos/o/r/issues/40/comments --input - --jq .html_url'
lacks "$LOG" 'issue create'

# An audit issue nobody has commented on: the body alone carries the marker.
CASE=report-existing-no-comments-unchanged
report "$AUDIT" DRY_RUN=false STUB_ISSUE_LIST="$OURS_40" STUB_ISSUE_BODY="first report <!-- $MARKER -->"
rc_is 0
writes_are 0
has "$OUT" 'nothing posted'
CASE=report-existing-no-comments-changed
report "$AUDIT" DRY_RUN=false STUB_ISSUE_LIST="$OURS_40" STUB_ISSUE_BODY="first report <!-- issue-labels-audit: 000000000000 -->"
rc_is 0
writes_are 1
has "$LOG" 'api -X POST repos/o/r/issues/40/comments --input - --jq .html_url'

CASE=report-existing-dry-run
report "$AUDIT" DRY_RUN=true STUB_ISSUE_LIST="$OURS_40"
rc_is 0
writes_are 0
has "$OUT" 'would comment on #40'

# An issue with the title that someone else opened is not the report target.
CASE=report-foreign-title-ignored
report "$AUDIT" DRY_RUN=false STUB_LABELS="$LABELS_CHORE_ONLY" \
  STUB_ISSUE_LIST="[{\"number\": 40, \"title\": \"Issue label audit\", \"author\": $HUMAN}]" \
  STUB_ISSUE_BODY="first report <!-- $MARKER -->"
rc_is 0
has "$LOG" 'issue create --repo o/r --title Issue label audit'
lacks "$LOG" 'issues/40'
CASE=report-foreign-title-beside-ours
report "$AUDIT" DRY_RUN=false \
  STUB_ISSUE_LIST="[{\"number\": 39, \"title\": \"Issue label audit\", \"author\": $HUMAN}, {\"number\": 40, \"title\": \"Issue label audit\", \"author\": $BOT}]" \
  STUB_ISSUE_BODY="first report <!-- issue-labels-audit: 000000000000 -->"
rc_is 0
writes_are 1
has "$LOG" 'api -X POST repos/o/r/issues/40/comments --input - --jq .html_url'
lacks "$LOG" 'issues/39'
lacks "$LOG" 'issue create'

CASE=report-create-fails
report "$AUDIT" DRY_RUN=false STUB_CREATE_FAIL=1
rc_is 1
lacks "$LOG" '/labels --input'
# The create call failed, but the issue it made is listed afterwards: adopt it,
# label and assign it, and do not file a second one.
CASE=report-create-fails-issue-exists
report "$AUDIT" DRY_RUN=false STUB_CREATE_FAIL=1 STUB_LABELS="$LABELS_CHORE_ONLY" \
  STUB_ISSUE_LIST_AFTER_CREATE="[{\"number\": 78, \"title\": \"Issue label audit\", \"author\": $BOT}]"
rc_is 0
has "$OUT" 'issue #78 exists; not retrying'
is "issue create calls" "$(grep -c '^issue create ' <<<"$LOG")" 1
has "$LOG" 'api -X POST repos/o/r/issues/78/labels --input - --silent'
has "$LOG" 'api -X POST repos/o/r/issues/78/assignees --input - --silent'
# ... but not an issue with that title someone else opened.
CASE=report-create-fails-foreign-exists
report "$AUDIT" DRY_RUN=false STUB_CREATE_FAIL=1 \
  STUB_ISSUE_LIST_AFTER_CREATE="[{\"number\": 78, \"title\": \"Issue label audit\", \"author\": $HUMAN}]"
rc_is 1
lacks "$LOG" 'issues/78'

# The label listing fails after the issue is filed: a warning, and the
# assignee is still set.
CASE=report-label-list-fails
report "$AUDIT" DRY_RUN=false STUB_LABEL_LIST_FAIL=1
rc_is 0
has "$OUT" '::warning title=Issue labels::listing the repository'"'"'s labels failed'
lacks "$LOG" '/labels --input'
has "$LOG" 'api -X POST repos/o/r/issues/77/assignees --input - --silent'
writes_are 2

CASE=report-malformed-audit
report '{"status": "ERROR", "reason": "gh api failed"}' DRY_RUN=false
rc_is 1
no_gh_calls

# ---- Sweep: report, repository without a taxonomy file (#152)
# An audit with no missing_routing finding does not read the taxonomy at all.
CASE=report-no-routing-findings
report "$AUDIT_NO_ROUTING" DRY_RUN=false STUB_LABELS="$LABELS_CHORE_ONLY" STUB_TAXONOMY=error
rc_is 0
lacks "$LOG" 'contents/'
BODY_NO_ROUTING="$(bodyfile)"
ok; [ -n "$BODY_NO_ROUTING" ] || fail "no body was filed"

# Without the file, the report is the one a repository with no missing_routing
# finding gets: same rows, same counts, same marker.
CASE=report-no-taxonomy
report "$AUDIT" DRY_RUN=false STUB_LABELS="$LABELS_CHORE_ONLY" STUB_TAXONOMY=absent
rc_is 0
has "$LOG" "$TAX_READ"
has "$LOG" 'issue create --repo o/r --title Issue label audit --body-file'
is "filed body" "$(bodyfile)" "$BODY_NO_ROUTING"
lacks "$LOG" 'missing_routing'
has "$LOG" 'BODYFILE #3  missing_type'
has "$LOG" 'BODYFILE #5  missing_type'
lacks "$LOG" "$MARKER"
lacks "$SUMMARY" '| `missing_routing`'
lacks "$SUMMARY" '[#9]'
has "$SUMMARY" '[#3](https://example.test/o/r/issues/3) | `missing_type`'
has "$SUMMARY" "no taxonomy file at \`$TAX\`"
has "$SUMMARY" '12 open issue(s), 3 finding(s)'
# The audit result the backfill step reads is left as the script wrote it.
ok; cmp -s <(printf '%s\n' "$AUDIT") "$work/audit-after-report.json" || fail "the report step changed the audit result file"

# An open audit issue whose latest marker is the no-routing set gets no comment.
CASE=report-no-taxonomy-existing-unchanged
NR_MARKER="$(sed -nE 's/^<!-- (issue-labels-audit: [0-9a-f]{12}) -->$/\1/p' <<<"$BODY_NO_ROUTING")"
report "$AUDIT" DRY_RUN=false STUB_TAXONOMY=absent STUB_ISSUE_LIST="$OURS_40" STUB_ISSUE_BODY="first report <!-- $NR_MARKER -->"
rc_is 0
writes_are 0
has "$OUT" 'nothing posted'

# Only missing_routing findings and no taxonomy: nothing to report, no issue.
CASE=report-no-taxonomy-only-routing
report "$AUDIT_ONLY_ROUTING" DRY_RUN=false STUB_TAXONOMY=absent STUB_ISSUE_LIST="$OURS_40"
rc_is 0
is "gh calls" "$LOG" "$TAX_READ"
has "$OUT" 'No findings'
has "$SUMMARY" '12 open issue(s), 0 finding(s)'
# ... and the same audit with a taxonomy file still files it.
CASE=report-taxonomy-only-routing
report "$AUDIT_ONLY_ROUTING" DRY_RUN=false STUB_LABELS="$LABELS_CHORE_ONLY"
rc_is 0
has "$LOG" 'issue create --repo o/r --title Issue label audit --body-file'
has "$LOG" 'BODYFILE #9  missing_routing'

CASE=report-no-taxonomy-dry-run
report "$AUDIT" DRY_RUN=true STUB_TAXONOMY=absent
rc_is 0
writes_are 0
has "$OUT" "would file an issue titled 'Issue label audit'"
has "$OUT" '#3  missing_type'
lacks "$OUT" '#9  missing_routing'
lacks "$OUT" '| `missing_routing`'
has "$OUT" 'No taxonomy file at'

# A failed read that is not a 404 is not "no taxonomy": the step fails before
# writing the summary or calling anything else, so no finding is dropped and
# the marker cannot change on a transient error.
CASE=report-taxonomy-read-fails
report "$AUDIT" DRY_RUN=false STUB_TAXONOMY=error STUB_ISSUE_LIST="$OURS_40"
rc_is 1
is "gh calls" "$LOG" "$TAX_READ"
has "$OUT" '::error title=Issue labels::'
has "$OUT" 'HTTP 502'
is "summary" "$SUMMARY" ""

# ---- Sweep: backfill
backfill() { # [VAR=value ...]; the audit result is $BACKFILL_AUDIT, else $AUDIT
  printf '%s\n' "${BACKFILL_AUDIT:-$AUDIT}" >"$work/audit.json"
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

# Backfill reads the taxonomy through the script only: a repository without the
# file still has its missing_routing issues (#9 here) classified.
CASE=backfill-no-taxonomy
backfill DRY_RUN=false MAX_ISSUES=25 STUB_TAXONOMY=absent
rc_is 0
has "$PY" "classify --repo o/r --issue 9 --taxonomy-path $TAX"
lacks "$LOG" 'contents/'
has "$LOG" 'api -X POST repos/o/r/issues/9/labels --input - --silent'

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

CASE=backfill-no-candidates
BACKFILL_AUDIT="$AUDIT_CLEAN" backfill DRY_RUN=false MAX_ISSUES=25
rc_is 0
is "script not called" "$PY" ""
no_gh_calls
has "$SUMMARY" '0 candidate(s) lack a type or routing label; 0 classified (max-issues: 25); 0 with labels to add.'
lacks "$SUMMARY" '| Issue |'

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

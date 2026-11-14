#!/usr/bin/env bash
# renovate-plugins-ref — renovate.json tracks every `plugins-ref` input default
# (a laurigates/claude-plugins commit SHA) in .github/workflows, and nothing
# else (#109).
#
# The pins come from yq (every `.on.workflow_call.inputs."plugins-ref".default`),
# not from the regex under test, so a pattern that misses a pin, or one that
# also rewrites another input's SHA, fails here:
#   - renovate.json parses and has exactly one git-refs customManager, with
#     packageNameTemplate https://github.com/laurigates/claude-plugins and
#     currentValueTemplate main (the branch whose head digest is tracked);
#   - managerFilePatterns cover every workflow that holds a pin;
#   - matchStrings capture only currentDigest (no currentValue, which would
#     replace the branch name), use no lookaround (Renovate compiles them with
#     RE2), and, run with Python's re over each workflow, find exactly the yq
#     pins, path by path;
#   - the same matchStrings, run over fixture input blocks, still match a
#     double-quoted or unquoted default and match nothing when plugins-ref has
#     no default and the next input has a 40-hex one, or when another input
#     name ends in plugins-ref;
#   - one packageRule groups this dependency, under a groupName of its own, on
#     a one-day-a-week schedule.
#
# The live lookup is not run here: that needs the Renovate CLI and network.
# The PR records a local `--platform=local --dry-run=lookup` run.
#
# Requires python3 (stdlib only) and yq (mikefarah v4).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

command -v yq >/dev/null || { echo "FAIL: renovate-plugins-ref: yq is required" >&2; exit 1; }

python3 - <<'PY'
import glob, json, re, subprocess, sys

NAME = "renovate-plugins-ref"
PACKAGE = "https://github.com/laurigates/claude-plugins"
SHA = re.compile(r"^[0-9a-f]{40}$")
failures, assertions = [], 0


def check(cond, msg):
    global assertions
    assertions += 1
    if not cond:
        failures.append(msg)


def finish():
    if failures:
        for f in failures:
            print(f"FAIL: {NAME}: {f}")
        print(f"FAIL: {NAME}: {len(failures)} of {assertions} assertion(s) failed")
        sys.exit(1)
    print(f"PASS: {NAME} ({assertions} assertion(s))")
    sys.exit(0)


def js_to_py(pattern):
    """Renovate's (?<name>…) named groups in Python's (?P<name>…) spelling."""
    return re.sub(r"\(\?<(?=[A-Za-z_])", "(?P<", pattern)


def slash_pattern(p):
    """A managerFilePatterns entry: /regex/ is a regex, anything else a glob."""
    m = re.fullmatch(r"/(.*)/([a-z]*)", p)
    return re.compile(m.group(1)) if m else None


WORKFLOWS = sorted(glob.glob(".github/workflows/*.yml") + glob.glob(".github/workflows/*.yaml"))

# ------------------------------------------------------------ the pins
pins = {}  # path -> SHA
for path in WORKFLOWS:
    out = subprocess.run(["yq", "-o=json", "-I=0", '.on.workflow_call.inputs."plugins-ref".default // null', path],
                         check=True, capture_output=True, text=True).stdout
    value = json.loads(out)
    if value is not None:
        pins[path] = value
check(len(pins) >= 2, f"yq found plugins-ref defaults in only {len(pins)} workflow(s); the scan is not reading the inputs")
for path, value in pins.items():
    check(isinstance(value, str) and SHA.match(value) is not None,
          f"{path}: plugins-ref default {value!r} is not a 40-hex commit SHA")

# ------------------------------------------------------- renovate.json
try:
    with open("renovate.json", encoding="utf-8") as fh:
        cfg = json.load(fh)
except (OSError, json.JSONDecodeError) as exc:
    check(False, f"renovate.json is missing or not JSON: {exc}")
    finish()

managers = [m for m in cfg.get("customManagers", []) if m.get("datasourceTemplate") == "git-refs"]
check(len(managers) == 1, f"expected one customManager on the git-refs datasource, found {len(managers)}")
if len(managers) != 1:
    finish()
mgr = managers[0]
check(mgr.get("customType") == "regex", "the plugins-ref customManager is not customType regex")
check(mgr.get("packageNameTemplate") == PACKAGE,
      f"packageNameTemplate must be {PACKAGE}, got {mgr.get('packageNameTemplate')!r}")
check(mgr.get("currentValueTemplate") == "main",
      f"currentValueTemplate must be the branch main, got {mgr.get('currentValueTemplate')!r}")
dep_name = mgr.get("depNameTemplate")
check(isinstance(dep_name, str) and dep_name != "", "the plugins-ref customManager has no depNameTemplate")

# --------------------------------------------------- file patterns
fps = mgr.get("managerFilePatterns", [])
compiled = [slash_pattern(p) for p in fps]
check(fps and all(c is not None for c in compiled), f"managerFilePatterns must be /regex/ entries: {fps!r}")
for path in pins:
    check(any(c and c.search(path) for c in compiled), f"managerFilePatterns do not cover {path}")
check(not any(c and c.search("README.md") for c in compiled), "managerFilePatterns also cover README.md")

# --------------------------------------------------- match strings
strings = mgr.get("matchStrings", [])
check(strings, "the plugins-ref customManager has no matchStrings")
for s in strings:
    check(not re.search(r"\(\?<?[=!]", s), f"matchString uses lookaround, which RE2 rejects: {s}")
    check("(?<currentDigest>" in s, f"matchString does not capture currentDigest: {s}")
    check("(?<currentValue>" not in s,
          f"matchString captures currentValue, which would overwrite currentValueTemplate main: {s}")
regexes = [re.compile(js_to_py(s)) for s in strings]


def digests(text):
    return sorted(m.groupdict().get("currentDigest") for rx in regexes for m in rx.finditer(text))


for path in WORKFLOWS:
    with open(path, encoding="utf-8") as fh:
        found = digests(fh.read())
    want = [pins[path]] if path in pins else []
    check(found == want, f"{path}: matchStrings found {found}, the yq plugins-ref default is {want}")

# Fixture input blocks: shapes the tree does not hold today.
A, B = "a" * 40, "b" * 40
fixtures = {
    "double-quoted default": (
        f'      plugins-ref:\n        description: "x"\n        type: string\n        default: "{A}"\n', [A]),
    "unquoted default after a comment": (
        f"      plugins-ref:\n        # bumped weekly\n        required: false\n        default: {A}\n", [A]),
    "no default, next input has a SHA": (
        f"      plugins-ref:\n        type: string\n      other-ref:\n        default: '{B}'\n", []),
    "input name only ends in plugins-ref": (
        f"      my-plugins-ref:\n        type: string\n        default: '{B}'\n", []),
    "41 hex characters": (
        f"      plugins-ref:\n        type: string\n        default: '{A}a'\n", []),
}
for label, (block, want) in fixtures.items():
    text = "    inputs:\n" + block
    check(digests(text) == want, f"fixture '{label}': matchStrings found {digests(text)}, expected {want}")

# ------------------------------------------------------- package rule
rules = [r for r in cfg.get("packageRules", [])
         if "git-refs" in r.get("matchDatasources", [])
         and (dep_name in r.get("matchDepNames", []) or PACKAGE in r.get("matchPackageNames", []))]
check(len(rules) == 1, f"expected one packageRule for the git-refs {dep_name} dependency, found {len(rules)}")
if len(rules) == 1:
    rule = rules[0]
    group = rule.get("groupName")
    check(isinstance(group, str) and group != "", "the plugins-ref packageRule has no groupName")
    others = [r.get("groupName") for r in cfg.get("packageRules", []) if r is not rule]
    check(group not in others, f"groupName {group!r} is shared with another packageRule")
    sched = rule.get("schedule")
    check(isinstance(sched, list) and len(sched) == 1, f"the plugins-ref packageRule needs one schedule entry, got {sched!r}")
    if isinstance(sched, list) and len(sched) == 1:
        fields = str(sched[0]).split()
        check(len(fields) == 5 and fields[:4] == ["*", "*", "*", "*"] and re.fullmatch(r"[0-6]", fields[4]) is not None,
              f"schedule {sched[0]!r} is not one whole day a week ('* * * * <0-6>')")

finish()
PY

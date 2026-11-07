#!/usr/bin/env bash
# renovate-model-pins — renovate.json tracks every Claude model ID pinned as a
# workflow_call input default in .github/workflows, and nothing else (#135).
#
# The pins come from yq (every `.on.workflow_call.inputs[].default` that names
# a claude-<line>-N-N model), not from the regex under test, so a pattern that
# misses a pin, or one that also rewrites prose, fails here:
#   - renovate.json parses; its one model customManager points at a
#     customDatasource declared beside it, served from api.anthropic.com (the
#     host reusable-renovate.yml authenticates when ANTHROPIC_API_KEY is set);
#   - managerFilePatterns cover every workflow that holds a pin;
#   - matchStrings, run with Python's re over each workflow, find exactly the
#     yq pins, with depName = the model line and currentValue = the full ID,
#     and use no lookaround (Renovate compiles them with RE2);
#   - versioningTemplate, rendered per line, accepts that line's IDs, orders
#     them by major then minor, and rejects other lines and dated snapshot IDs.
#     Renovate's regex versioning runs RegExp.exec, an unanchored search, so
#     the checks use re.search: the template's own ^ and $ do the anchoring.
#
# The JSONata transform and the live lookup are not run here: that needs the
# Renovate CLI. The PR records a local `--platform=local` run against an API
# response fixture.
#
# Requires python3 (stdlib only) and yq (mikefarah v4).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

command -v yq >/dev/null || { echo "FAIL: renovate-model-pins: yq is required" >&2; exit 1; }

python3 - <<'PY'
import glob, json, re, subprocess, sys

NAME = "renovate-model-pins"
MODEL = re.compile(r"^claude-(opus|sonnet|haiku|fable)-\d+-\d+$")
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


# ------------------------------------------------------------ the pins
pins = {}  # path -> sorted list of model IDs
for path in sorted(glob.glob(".github/workflows/*.yml") + glob.glob(".github/workflows/*.yaml")):
    out = subprocess.run(["yq", "-o=json", "-I=0", "[.on.workflow_call.inputs[]?.default // \"\"]", path],
                         check=True, capture_output=True, text=True).stdout
    ids = sorted(v for v in json.loads(out) if isinstance(v, str) and MODEL.match(v))
    if ids:
        pins[path] = ids
check(len(pins) >= 2, f"yq found model pins in only {len(pins)} workflow(s); the scan is not reading the inputs")
lines_pinned = {MODEL.match(v).group(1) for ids in pins.values() for v in ids}

# ------------------------------------------------------- renovate.json
try:
    with open("renovate.json", encoding="utf-8") as fh:
        cfg = json.load(fh)
except (OSError, json.JSONDecodeError) as exc:
    check(False, f"renovate.json is missing or not JSON: {exc}")
    finish()

managers = [m for m in cfg.get("customManagers", [])
            if str(m.get("datasourceTemplate", "")).startswith("custom.")]
check(len(managers) == 1, f"expected one customManager on a custom datasource, found {len(managers)}")
if len(managers) != 1:
    finish()
mgr = managers[0]
check(mgr.get("customType") == "regex", "the model customManager is not customType regex")

ds_name = mgr["datasourceTemplate"][len("custom."):]
ds = cfg.get("customDatasources", {}).get(ds_name)
check(isinstance(ds, dict), f"customDatasources has no '{ds_name}' entry")
if isinstance(ds, dict):
    url = str(ds.get("defaultRegistryUrlTemplate", ""))
    check(url.startswith("https://api.anthropic.com/v1/models"),
          f"'{ds_name}' must read GET https://api.anthropic.com/v1/models, got '{url}'")
    check("limit=1000" in url, f"'{ds_name}' must request limit=1000 (the API default page is 20 models): '{url}'")
    check(ds.get("format") == "json", f"'{ds_name}' format must be json")
    check(isinstance(ds.get("transformTemplates"), list) and len(ds["transformTemplates"]) == 1,
          f"'{ds_name}' must have exactly one transformTemplate")

# --------------------------------------------------- file patterns
fps = mgr.get("managerFilePatterns", [])
compiled = [slash_pattern(p) for p in fps]
check(fps and all(c is not None for c in compiled), f"managerFilePatterns must be /regex/ entries: {fps!r}")
for path in pins:
    check(any(c and c.search(path) for c in compiled), f"managerFilePatterns do not cover {path}")
check(not any(c and c.search("README.md") for c in compiled), "managerFilePatterns also cover README.md")

# --------------------------------------------------- match strings
strings = mgr.get("matchStrings", [])
check(strings, "the model customManager has no matchStrings")
for s in strings:
    check(not re.search(r"\(\?<?[=!]", s), f"matchString uses lookaround, which RE2 rejects: {s}")
regexes = [re.compile(js_to_py(s)) for s in strings]
for path in sorted(glob.glob(".github/workflows/*.yml") + glob.glob(".github/workflows/*.yaml")):
    text = open(path, encoding="utf-8").read()
    found = []
    for rx in regexes:
        for m in rx.finditer(text):
            d = m.groupdict()
            found.append(d.get("currentValue"))
            cv = d.get("currentValue") or ""
            line = MODEL.match(cv)
            check(line is not None and d.get("depName") == f"claude-{line.group(1)}",
                  f"{path}: match gives depName {d.get('depName')!r} for currentValue {cv!r}")
    check(sorted(found) == pins.get(path, []),
          f"{path}: matchStrings found {sorted(found)}, yq input defaults are {pins.get(path, [])}")

# ------------------------------------------------------- versioning
tmpl = str(mgr.get("versioningTemplate", ""))
check(tmpl.startswith("regex:") and "{{{depName}}}" in tmpl,
      f"versioningTemplate must be a regex: versioning keyed on {{{{{{depName}}}}}}, got '{tmpl}'")


def version_rx(line):
    return re.compile(js_to_py(tmpl[len("regex:"):].replace("{{{depName}}}", f"claude-{line}")))


def key(rx, v):
    m = rx.search(v)
    return (int(m.group("major")), int(m.group("minor"))) if m else None


if tmpl.startswith("regex:"):
    for line in sorted(lines_pinned | {"opus", "sonnet", "haiku", "fable"}):
        rx = version_rx(line)
        check(all(rx.search(v) for ids in pins.values() for v in ids if v.startswith(f"claude-{line}-")),
              f"{line}: the versioning regex rejects a pinned ID")
        a, b, c = (key(rx, f"claude-{line}-{x}") for x in ("5-5", "5-10", "6-0"))
        check(None not in (a, b, c) and a < b < c, f"{line}: versioning does not order 5-5 < 5-10 < 6-0")
        other = "sonnet" if line != "sonnet" else "opus"
        check(rx.search(f"claude-{other}-9-9") is None, f"{line}: versioning accepts claude-{other}-9-9")
        check(rx.search(f"us.anthropic.claude-{line}-9-9") is None,
              f"{line}: versioning accepts the prefixed ID us.anthropic.claude-{line}-9-9")
        check(rx.search(f"claude-{line}-4-5-20251001") is None,
              f"{line}: versioning accepts the dated snapshot claude-{line}-4-5-20251001")

finish()
PY

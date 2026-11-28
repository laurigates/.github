#!/usr/bin/env bash
# renovate-binary-pins — renovate.json tracks every `<TOOL>_VERSION` pin of a
# release binary the reusable workflows download and checksum-check (#166).
#
# The pins come from yq (every step `env:` key ending in _VERSION in the
# workflows listed in PINNED below), not from the regexes under test, and the
# GitHub repository and tag spelling come from the same step's download URL
# (https://github.com/<owner>/<repo>/releases/download/<tag>/...), so a
# manager that misses a pin, names another repository or drops the tag's `v`
# fails here:
#   - renovate.json parses; each pin is matched by exactly one regex
#     customManager on the github-releases datasource, whose
#     packageNameTemplate and depNameTemplate are the repository in the URL;
#   - managerFilePatterns cover the pin's workflow;
#   - matchStrings use no lookaround (Renovate compiles them with RE2), and,
#     run with Python's re over each workflow, capture exactly the yq pins as
#     currentValue, and nothing in any other workflow (lint.yml's actionlint
#     and ShellCheck pins are tracked by hand; see tool-pins);
#   - extractVersionTemplate, applied to the release tag the URL builds from
#     the pin, gives back the pin, and rejects a pre-release tag.
#
# Renovate cannot write the new <TOOL>_SHA256, so a bump PR arrives red and the
# checksum is edited on it (CLAUDE.md, tool-pins entry). The live lookup is not
# run here: that needs the Renovate CLI and network.
#
# Requires python3 (stdlib only) and yq (mikefarah v4).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

command -v yq >/dev/null || { echo "FAIL: renovate-binary-pins: yq is required" >&2; exit 1; }

python3 - <<'PY'
import glob, json, re, subprocess, sys

NAME = "renovate-binary-pins"
PINNED = [
    ".github/workflows/reusable-security-secrets.yml",
    ".github/workflows/reusable-security-deps.yml",
    ".github/workflows/reusable-opencode-review.yml",
    ".github/workflows/reusable-quality-code-smell.yml",
]
URL = re.compile(r"https://github\.com/(?P<repo>[\w.-]+/[\w.-]+)/releases/download/(?P<tag>[^/\s\"']+)/")
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
# pins[path] = [(var, version, repo, tag_template)]
pins = {}
for path in PINNED:
    out = subprocess.run(
        ["yq", "-o=json", "-I=0",
         '[.jobs[].steps[]? | select(.env != null) | {"env": .env, "run": (.run // "")}]', path],
        check=True, capture_output=True, text=True).stdout
    found = []
    for step in json.loads(out):
        for var, value in step["env"].items():
            if not var.endswith("_VERSION"):
                continue
            check(isinstance(value, str) and re.fullmatch(r"\d+\.\d+\.\d+", value) is not None,
                  f"{path}: {var} {value!r} is not an exact X.Y.Z version")
            urls = [m for m in URL.finditer(step["run"]) if "${" + var + "}" in m.group("tag")]
            check(len(urls) == 1, f"{path}: expected one release download URL built from ${{{var}}}, found {len(urls)}")
            if urls:
                found.append((var, str(value), urls[0].group("repo"), urls[0].group("tag")))
    check(found, f"{path}: yq found no step env *_VERSION pin; the scan is not reading the workflow")
    pins[path] = found

# ------------------------------------------------------- renovate.json
try:
    with open("renovate.json", encoding="utf-8") as fh:
        cfg = json.load(fh)
except (OSError, json.JSONDecodeError) as exc:
    check(False, f"renovate.json is missing or not JSON: {exc}")
    finish()

managers = [m for m in cfg.get("customManagers", []) if m.get("datasourceTemplate") == "github-releases"]
check(managers, "renovate.json has no customManager on the github-releases datasource")
compiled = []  # (manager, [regex])
for m in managers:
    check(m.get("customType") == "regex", f"github-releases manager {m.get('depNameTemplate')!r} is not customType regex")
    strings = m.get("matchStrings", [])
    check(strings, f"github-releases manager {m.get('depNameTemplate')!r} has no matchStrings")
    for s in strings:
        check(not re.search(r"\(\?<?[=!]", s), f"matchString uses lookaround, which RE2 rejects: {s}")
        check("(?<currentValue>" in s, f"matchString does not capture currentValue: {s}")
    compiled.append((m, [re.compile(js_to_py(s)) for s in strings]))


def matches(text):
    """Every (manager, currentValue) the github-releases managers capture."""
    return [(m, hit.groupdict().get("currentValue")) for m, rxs in compiled for rx in rxs for hit in rx.finditer(text)]


for path in WORKFLOWS:
    with open(path, encoding="utf-8") as fh:
        hits = matches(fh.read())
    if path not in pins:
        check(not hits, f"{path}: github-releases managers match {[v for _, v in hits]} outside the pinned "
                        "workflows; add the workflow to PINNED in this test")
        continue
    check(sorted(v for _, v in hits) == sorted(v for _, v, _, _ in pins[path]),
          f"{path}: matchStrings capture {sorted(v for _, v in hits)}, the yq pins are "
          f"{sorted(v for _, v, _, _ in pins[path])}")
    for var, version, repo, tag_tmpl in pins[path]:
        owners = [m for m, v in hits if v == version and m.get("packageNameTemplate") == repo]
        check(len(owners) == 1, f"{path}: {var} {version} is matched by {len(owners)} manager(s) "
                                f"with packageNameTemplate {repo!r}, expected 1")
        if len(owners) != 1:
            continue
        mgr = owners[0]
        check(mgr.get("depNameTemplate") == repo,
              f"{path}: {var}: depNameTemplate {mgr.get('depNameTemplate')!r} is not the repository {repo!r}")
        fps = mgr.get("managerFilePatterns", [])
        fpc = [slash_pattern(p) for p in fps]
        check(fps and all(c is not None for c in fpc), f"{repo}: managerFilePatterns must be /regex/ entries: {fps!r}")
        check(any(c and c.search(path) for c in fpc), f"{repo}: managerFilePatterns do not cover {path}")
        evt = str(mgr.get("extractVersionTemplate", ""))
        check(evt != "", f"{repo}: no extractVersionTemplate; Renovate would compare raw tags")
        if evt:
            rx = re.compile(js_to_py(evt))
            tag = tag_tmpl.replace("${" + var + "}", version)
            got = rx.search(tag)
            check(got is not None and got.groupdict().get("version") == version,
                  f"{repo}: extractVersionTemplate {evt!r} gives "
                  f"{got.groupdict().get('version') if got else None!r} for the tag {tag!r}, expected {version!r}")
            pre = tag_tmpl.replace("${" + var + "}", version + "-rc.1")
            check(rx.search(pre) is None, f"{repo}: extractVersionTemplate accepts the pre-release tag {pre!r}")

# Every github-releases manager belongs to a pin.
owned = {repo for found in pins.values() for _, _, repo, _ in found}
for m in managers:
    check(m.get("packageNameTemplate") in owned,
          f"github-releases manager {m.get('packageNameTemplate')!r} tracks no pin in {PINNED}")

finish()
PY

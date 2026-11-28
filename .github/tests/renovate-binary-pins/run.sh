#!/usr/bin/env bash
# renovate-binary-pins — renovate.json tracks every `<TOOL>_VERSION` pin of a
# release binary the reusable workflows download and checksum-check (#166).
#
# The pins come from yq (every `env:` key ending in _VERSION, at workflow, job
# or step level, in the workflows listed in PINNED below; a fixture workflow
# checks all three levels are read), not from the regexes under test, and the
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
#     the pin, gives back the pin, and rejects a pre-release tag;
#     versioningTemplate is semver;
#   - the manager's description matches what CI does with a stale
#     <TOOL>_SHA256. Renovate cannot write it, and only a test that runs the
#     shipped install for real on Linux x86_64 (gitleaks-guard,
#     osv-scanner-job) fails on it. Such a pin's description says the PR
#     "fails its checksum check"; any other pin's (opencode, ruff, whose tests
#     install a stub tarball with its own hash) must not, and says the hash is
#     replaced "before merging" (CLAUDE.md, tool-pins entry).
#
# The live lookup is not run here: that needs the Renovate CLI and network.
#
# Requires python3 (stdlib only) and yq (mikefarah v4).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

command -v yq >/dev/null || { echo "FAIL: renovate-binary-pins: yq is required" >&2; exit 1; }

python3 - <<'PY'
import glob, json, os, re, subprocess, sys, tempfile

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
# An env: block at workflow, job or step level, each with the run: text its
# variables reach: every step for workflow env, the job's steps for job env.
# Every level emits a block, with env {} when it has none, and Python skips the
# empty ones: with yq v4.47, select(.env != null) inside these collects let
# env-less levels through as objects without an env key.
ENV_BLOCKS = (
    '[((.env // {}) as $e | ([.jobs[].steps[]? | (.run // "")] | join("\\n")) as $r'
    ' | {"env": $e, "run": $r}),'
    ' (.jobs[] | (.env // {}) as $e | ([.steps[]? | (.run // "")] | join("\\n")) as $r'
    ' | {"env": $e, "run": $r}),'
    ' (.jobs[].steps[]? | {"env": (.env // {}), "run": (.run // "")})]'
)


def read_pins(path):
    """[(var, version, repo, tag_template)] for every *_VERSION key in an env: block of path."""
    out = subprocess.run(["yq", "-o=json", "-I=0", ENV_BLOCKS, path],
                         check=True, capture_output=True, text=True).stdout
    found = []
    for block in json.loads(out):
        for var, value in (block.get("env") or {}).items():
            if not var.endswith("_VERSION"):
                continue
            check(isinstance(value, str) and re.fullmatch(r"\d+\.\d+\.\d+", value) is not None,
                  f"{path}: {var} {value!r} is not an exact X.Y.Z version")
            urls = [m for m in URL.finditer(block["run"]) if "${" + var + "}" in m.group("tag")]
            check(len(urls) == 1, f"{path}: expected one release download URL built from ${{{var}}}, found {len(urls)}")
            if urls:
                found.append((var, str(value), urls[0].group("repo"), urls[0].group("tag")))
    return found


# The scan reads all three env: levels: a pin moved to job or workflow env is
# still checked, not skipped.
with tempfile.TemporaryDirectory() as tmp:
    fixture = os.path.join(tmp, "levels.yml")
    with open(fixture, "w", encoding="utf-8") as fh:
        fh.write(
            "env:\n  WF_VERSION: 1.0.0\n"
            "jobs:\n  a:\n    env:\n      JOB_VERSION: 2.0.0\n"
            "    steps:\n      - env:\n          STEP_VERSION: 3.0.0\n"
            "        run: |\n"
            "          curl https://github.com/o/wf/releases/download/v${WF_VERSION}/x.tgz\n"
            "          curl https://github.com/o/job/releases/download/v${JOB_VERSION}/x.tgz\n"
            "          curl https://github.com/o/step/releases/download/v${STEP_VERSION}/x.tgz\n")
    got = sorted((v, ver, repo) for v, ver, repo, _ in read_pins(fixture))
    check(got == [("JOB_VERSION", "2.0.0", "o/job"), ("STEP_VERSION", "3.0.0", "o/step"),
                  ("WF_VERSION", "1.0.0", "o/wf")],
          f"the pin scan does not read workflow, job and step env: alike; it found {got}")

# pins[path] = [(var, version, repo, tag_template)]
pins = {}
for path in PINNED:
    found = read_pins(path)
    check(found, f"{path}: yq found no env *_VERSION pin; the scan is not reading the workflow")
    pins[path] = found

# A pin is checksum-gated here when a test runs the workflow's shipped install
# step for real on Linux x86_64 (the "$(uname -s)/$(uname -m)" = Linux/x86_64
# branch of gitleaks-guard and osv-scanner-job), so a version-only bump fails
# that checksum check. Elsewhere the install runs against a stub tarball with
# its own hash, and a stale *_SHA256 does not turn the PR red.
REAL_INSTALL = re.compile(r'^\s*if \[ "\$\(uname -s\)/\$\(uname -m\)" = Linux/x86_64 \]; then$', re.M)
TESTS = {}
for t in sorted(glob.glob(".github/tests/*/run.sh")):
    if t == f".github/tests/{NAME}/run.sh":
        continue  # this file names every pinned workflow and the guard
    with open(t, encoding="utf-8") as fh:
        TESTS[t] = fh.read()


def checksum_gated(path):
    base = os.path.basename(path)
    return [t for t, body in TESTS.items() if base in body and REAL_INSTALL.search(body)]


check(sorted(t for p in PINNED for t in checksum_gated(p))
      == [".github/tests/gitleaks-guard/run.sh", ".github/tests/osv-scanner-job/run.sh"],
      "the real-install scan no longer finds exactly gitleaks-guard and osv-scanner-job: "
      f"{sorted(t for p in PINNED for t in checksum_gated(p))}; update the manager descriptions and this test")

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
        check(mgr.get("versioningTemplate") == "semver",
              f"{repo}: versioningTemplate {mgr.get('versioningTemplate')!r} is not 'semver'")
        # The description tells the reviewer of the bump PR whether CI catches
        # the stale *_SHA256, so it must match what the tests actually run.
        desc = str(mgr.get("description", ""))
        gated = checksum_gated(path)
        if gated:
            check("fails its checksum check" in desc,
                  f"{repo}: {gated[0]} runs the real install, so a bump PR fails its checksum check; "
                  "the manager description must say so")
        else:
            check("fails its checksum check" not in desc,
                  f"{repo}: no test runs the real install of {path}, so a version-only bump does not "
                  "fail a checksum check; the manager description claims it does")
            check("before merging" in desc,
                  f"{repo}: no test catches a stale {var.replace('_VERSION', '_SHA256')}; the manager "
                  "description must say the hash is replaced before merging")
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

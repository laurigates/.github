#!/usr/bin/env bash
# tool-pins — every lint/sync toolchain version is pinned exactly and agrees
# across the files that use it.
#
#   rulesync    every npx/bunx/pnpx invocation in the workflows, justfile,
#               docs, rule sources, scripts and tests carries @X.Y.Z; no
#               @latest, no bare name; one version everywhere, and both
#               lint.yml and reusable-sync-ai-rules.yml run it. rulesync ships
#               a major almost daily and every consumer runs the sync workflow
#               at @main, so a floating version changes their generated files
#               (or breaks generate) with no change here.
#   actionlint  lint.yml's ACTIONLINT_VERSION equals the justfile's
#               actionlint_version and is X.Y.Z; ACTIONLINT_SHA256 is 64 hex
#               characters and the step that downloads the binary checks it
#               with `sha256sum -c`. The justfile runs no tool at @latest.
#   ShellCheck  the same checks as actionlint, for SHELLCHECK_VERSION /
#               SHELLCHECK_SHA256 and the justfile's shellcheck_version.
#
# Nothing here tracks these versions automatically (this repo has no
# renovate.json); a bump edits every site, and this test fails until they agree.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

command -v yq >/dev/null || { echo "FAIL: tool-pins: yq not found on PATH"; exit 1; }

python3 - <<'PY'
import glob
import os
import re
import subprocess
import sys

NAME = "tool-pins"
SEMVER = re.compile(r"^\d+\.\d+\.\d+$")
failures, assertions = [], 0


def check(cond, msg):
    global assertions
    assertions += 1
    if not cond:
        failures.append(msg)


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def yq(expr, path):
    return subprocess.run(["yq", expr, path], check=True, capture_output=True, text=True).stdout


def lineno(text, pos):
    return text.count("\n", 0, pos) + 1


workflows = sorted(glob.glob(".github/workflows/*.yml") + glob.glob(".github/workflows/*.yaml"))
check(workflows, "found no .github/workflows/*.yml files")
justfile = read("justfile")


def just_var(name):
    m = re.search(rf'^{name}\s*:=\s*"([^"]*)"\s*$', justfile, re.M)
    return m.group(1) if m else None


# ---------------------------------------------------------------- rulesync
# A rulesync run through a package runner. The version (if any) is the @...
# suffix; `npx rulesync:*`-style permission patterns have no whitespace after
# the name and are not runs.
RUNNER = re.compile(
    r"\b(?:npx|bunx|pnpx|dlx)\b(?:\s+-{1,2}[\w-]+)*\s+[\"']?rulesync"
    r"(?:@(?P<ver>[^\s`'\")]+))?(?=\s|$|[`'\")])"
)
scan = sorted(set(
    workflows
    + ["justfile", "README.md", "CLAUDE.md"]
    + glob.glob(".claude/rules/*.md") + glob.glob(".claude/skills/*.md") + glob.glob(".rulesync/rules/*.md")
    + glob.glob("scripts/*") + glob.glob(".github/tests/*/run.sh") + glob.glob(".github/tests/README.md")
))
scan = [p for p in scan if os.path.isfile(p)]
rulesync_sites = []  # (path, line, version)
for path in scan:
    text = read(path)
    for m in RUNNER.finditer(text):
        ver, where = m.group("ver"), f"{path}:{lineno(text, m.start())}"
        assertions += 1
        if ver is None:
            failures.append(f"{where}: unpinned rulesync run `{m.group(0).strip()}`; pin rulesync@X.Y.Z")
            continue
        if not SEMVER.match(ver):
            failures.append(f"{where}: rulesync@{ver} is not an exact X.Y.Z version")
            continue
        rulesync_sites.append((path, lineno(text, m.start()), ver))

# A direct `rulesync fetch|generate` (no runner) inside a workflow run: body
# or the justfile would resolve whatever is on PATH. Comments and a step's
# `name:` are prose, not runs.
DIRECT = re.compile(r"(?:^|[\s;&|(])rulesync(?:@\S+)?\s+(?:fetch|generate)\b")
PROSE = re.compile(r"^\s*(?:#|(?:-\s+)?name:)")
for path in workflows + ["justfile"]:
    for no, line in enumerate(read(path).splitlines(), 1):
        if PROSE.match(line):
            continue
        for m in DIRECT.finditer(line):
            check(RUNNER.search(line[: m.end()]) is not None,
                  f"{path}:{no}: `rulesync` run without npx and a pinned version: {line.strip()}")

for must in (".github/workflows/lint.yml", ".github/workflows/reusable-sync-ai-rules.yml"):
    check(any(p == must for p, _, _ in rulesync_sites), f"found no pinned rulesync run in {must}")
rs_versions = sorted({v for _, _, v in rulesync_sites})
check(len(rs_versions) == 1,
      f"expected one rulesync version everywhere, found {rs_versions}: "
      + ", ".join(f"{p}:{n}={v}" for p, n, v in sorted(set(rulesync_sites))))

# ------------------------------------------------- actionlint, shellcheck
for m in re.finditer(r"@latest\b", justfile):
    failures.append(f"justfile:{lineno(justfile, m.start())}: a tool is run at @latest; pin it")
assertions += 1


def check_binary_pin(tool):
    """lint.yml downloads <tool> at <TOOL>_VERSION, verified against
    <TOOL>_SHA256; the justfile runs it at {{ <tool>_version }}."""
    env = tool.upper()
    jv = just_var(f"{tool}_version")
    check(jv is not None and SEMVER.match(jv or ""), f"justfile: {tool}_version := \"X.Y.Z\" missing or not exact (got {jv!r})")
    check(re.search(rf"{tool}@\{{\{{\s*{tool}_version\s*\}}\}}", justfile) is not None,
          f"justfile: {tool} is not run at {{{{ {tool}_version }}}}")
    found_lint = False
    shas = set()
    for path in workflows:
        text = read(path)
        for m in re.finditer(rf"^[ \t]*{env}_VERSION:[ \t]*(\S+)[ \t]*$", text, re.M):
            v = m.group(1).strip("'\"")
            where = f"{path}:{lineno(text, m.start())}"
            found_lint = found_lint or path == ".github/workflows/lint.yml"
            check(SEMVER.match(v), f"{where}: {env}_VERSION {v!r} is not an exact X.Y.Z version")
            check(v == jv, f"{where}: {env}_VERSION {v} != justfile {tool}_version {jv}")
        for m in re.finditer(rf"^[ \t]*{env}_SHA256:[ \t]*(\S+)[ \t]*$", text, re.M):
            s = m.group(1).strip("'\"")
            check(re.fullmatch(r"[0-9a-f]{64}", s), f"{path}:{lineno(text, m.start())}: {env}_SHA256 is not 64 lowercase hex characters")
            shas.add(s)
        body = yq(f'[.jobs[].steps[] | select(.env.{env}_VERSION != null) | .run] | join("\\n---\\n")', path)
        if body.strip():
            check(f"${{{env}_SHA256}}" in body and "sha256sum -c" in body,
                  f"{path}: the step with {env}_VERSION does not verify ${{{env}_SHA256}} with sha256sum -c")
    check(found_lint, f".github/workflows/lint.yml has no {env}_VERSION")
    check(len(shas) == 1, f"{env}_SHA256 is missing or differs between workflows: {sorted(shas)}")
    return jv


pins = {tool: check_binary_pin(tool) for tool in ("actionlint", "shellcheck")}

if failures:
    for f in failures:
        print(f"FAIL: {NAME}: {f}", file=sys.stderr)
    sys.exit(1)
print(f"pins: rulesync {rs_versions[0]}, " + ", ".join(f"{t} {v}" for t, v in pins.items()))
print(f"PASS: {NAME} ({assertions} assertion(s))")
PY

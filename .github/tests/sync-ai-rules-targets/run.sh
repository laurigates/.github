#!/usr/bin/env bash
# Pins the two silent-zero-files traps in every rulesync invocation shipped by
# this repo's reusable workflows:
#
#   generate  must pass --features equal to this repo's rulesync.jsonc, and
#             --targets either equal to it or as "$TARGETS", the validated
#             `targets` input of a workflow that has one (that form is
#             checked only when present). A consuming repo has no rulesync.jsonc
#             (fetch pulls only .rulesync/), and a bare `generate` then
#             resolves to the agentsmd target alone and writes zero files at
#             exit 0. For the input form, the step's `allowed` list must equal
#             rulesync.jsonc targets, the input default must be a subset of it,
#             and the shipped step body is run against a stubbed npx: valid
#             subsets reach generate verbatim, anything else exits 1 first.
#   fetch     must pass --path .rulesync. rulesync >= 9 resolves features
#             against the source repo root, so without it the fetch 404s on
#             rules/ and returns zero files at exit 0. Its step must also bind
#             GITHUB_TOKEN or GH_TOKEN: unauthenticated, rulesync shares the
#             hosted runners' 60-requests-an-hour anonymous limit and fails
#             intermittently with "API rate limit exceeded".
#
# The commands are extracted from the shipped workflow text, not retyped here.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

python3 - <<'PY'
import glob
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile

NAME = "sync-ai-rules-targets"


def strip_jsonc(text):
    """Drop // and /* */ comments outside strings, then trailing commas."""
    out, i, n, in_str = [], 0, len(text), False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if c == '"':
                in_str = False
            i += 1
        elif c == '"':
            in_str = True
            out.append(c)
            i += 1
        elif text.startswith("//", i):
            while i < n and text[i] != "\n":
                i += 1
        elif text.startswith("/*", i):
            end = text.find("*/", i + 2)
            if end < 0:
                sys.exit(f"FAIL: {NAME}: unterminated /* comment in rulesync.jsonc")
            i = end + 2
        else:
            out.append(c)
            i += 1
    return re.sub(r",(\s*[}\]])", r"\1", "".join(out))


with open("rulesync.jsonc", encoding="utf-8") as fh:
    config = json.loads(strip_jsonc(fh.read()))
want_targets = config.get("targets")
want_features = config.get("features")
if not isinstance(want_targets, list) or not want_targets:
    sys.exit(f"FAIL: {NAME}: rulesync.jsonc has no array 'targets' (the object form is not handled by this test)")
if not isinstance(want_features, list) or not want_features:
    sys.exit(f"FAIL: {NAME}: rulesync.jsonc has no array 'features'")

# Only what a consuming repo runs: the reusable workflows. Workflows local to
# this repo (lint.yml's scratch-dir `generate`) run next to a copy of this
# repo's own rulesync.jsonc, so the no-config trap cannot reach them.
files = sorted(
    glob.glob(".github/workflows/reusable-*.yml")
    + glob.glob(".github/workflows/reusable-*.yaml")
)
if not files:
    sys.exit(f"FAIL: {NAME}: found no workflow files to scan")


def logical_lines(path):
    """Yield (lineno, text): backslash continuations joined, YAML comment lines skipped."""
    buf, start = "", None
    with open(path, encoding="utf-8") as fh:
        for no, raw in enumerate(fh, 1):
            line = raw.rstrip("\n")
            if not buf and line.lstrip().startswith("#"):
                continue
            if start is None:
                start = no
            if line.rstrip().endswith("\\"):
                buf += line.rstrip()[:-1] + " "
                continue
            yield start, buf + line
            buf, start = "", None
    if buf:
        yield start, buf


# Matches a rulesync fetch or generate with or without an @<version> suffix,
# run directly or through npx and its flags. tool-pins checks the version.
INVOCATION = re.compile(r"(?:^|[\s;&|(`'\"])rulesync(?:@\S+)?\s+(fetch|generate)\b([^;&|\n]*)")


def flag_value(tokens, long, short):
    for k, tok in enumerate(tokens):
        if tok in (long, short) and k + 1 < len(tokens):
            return tokens[k + 1]
        if tok.startswith(long + "="):
            return tok.split("=", 1)[1]
    return None


failures, assertions, counts = [], 0, {"fetch": 0, "generate": 0}
input_checked = set()


def yq(expr, path):
    return subprocess.run(["yq", expr, path], check=True, capture_output=True, text=True).stdout.strip()


def check_targets_input(path, where):
    """The `targets` input path: allowed list, default, and step behaviour."""
    global assertions
    if path in input_checked:
        return
    input_checked.add(path)
    body = yq('.jobs[].steps[] | select(.run // "" | test("rulesync@\\S+ generate")) | .run', path)
    m = re.search(r'^\s*allowed="([^"]*)"', body, re.M)
    assertions += 1
    if not m:
        failures.append(f"{where}: --targets \"$TARGETS\" but the step defines no allowed=\"...\" list")
        return
    allowed = m.group(1).split()
    assertions += 1
    if allowed != want_targets:
        failures.append(f"{where}: allowed {allowed} != rulesync.jsonc targets {want_targets}")
    default = yq(".on.workflow_call.inputs.targets.default", path)
    assertions += 1
    if default in ("", "null") or not set(default.split(",")) <= set(want_targets):
        failures.append(f"{where}: targets input default '{default}' is not a non-empty subset of {want_targets}")
    env_t = yq('.jobs[].steps[] | select(.run // "" | test("rulesync@\\S+ generate")) | .env.TARGETS', path)
    assertions += 1
    if env_t != "${{ inputs.targets }}":
        failures.append(f"{where}: step env TARGETS is '{env_t}', expected '${{{{ inputs.targets }}}}'")

    # The pinned version is read from the shipped body (tool-pins checks it),
    # so a Renovate bump of the pin does not break this test.
    pin = re.search(r"\brulesync@(\S+) generate\b", body)
    assertions += 1
    if not pin:
        failures.append(f"{where}: the generate step runs no `rulesync@<version> generate`")
        return
    want_call = f"STUB-NPX rulesync@{pin.group(1)} generate --targets"
    with tempfile.TemporaryDirectory() as tmp:
        stub = os.path.join(tmp, "npx")
        with open(stub, "w") as fh:
            fh.write('#!/usr/bin/env bash\necho "STUB-NPX $*"\n')
        os.chmod(stub, 0o755)
        env = dict(os.environ, PATH=f"{tmp}:{os.environ['PATH']}")
        cases = [(t, True) for t in [default, ",".join(want_targets), want_targets[-1]]]
        cases += [(t, False) for t in ["", "agentsmd", f"{want_targets[0]},", f"{want_targets[0]}, {want_targets[1]}", "claudecode;id"]]
        for value, ok in cases:
            r = subprocess.run(["bash", "-c", body], env=dict(env, TARGETS=value), capture_output=True, text=True)
            assertions += 1
            called = "STUB-NPX" in r.stdout
            if ok and (r.returncode != 0 or f"{want_call} {value} --features" not in r.stdout):
                failures.append(f"{where}: targets '{value}' should reach generate verbatim; rc={r.returncode} out={r.stdout!r} err={r.stderr!r}")
            if not ok and (r.returncode == 0 or called):
                failures.append(f"{where}: targets '{value}' should be refused before generate; rc={r.returncode} out={r.stdout!r}")
for path in files:
    for lineno, text in logical_lines(path):
        for match in INVOCATION.finditer(text):
            sub, rest = match.group(1), match.group(2)
            counts[sub] += 1
            where = f"{path}:{lineno}"
            try:
                tokens = shlex.split(rest, comments=True)
            except ValueError as err:
                failures.append(f"{where}: cannot tokenize rulesync {sub} arguments ({err})")
                continue
            if sub == "generate":
                got_t = flag_value(tokens, "--targets", "-t")
                got_f = flag_value(tokens, "--features", "-f")
                assertions += 2
                if got_t == "$TARGETS":
                    check_targets_input(path, where)
                elif got_t is None:
                    failures.append(
                        f"{where}: `rulesync generate` has no --targets; a caller without rulesync.jsonc "
                        f"generates only agentsmd (zero files). Expected --targets {','.join(want_targets)}"
                    )
                elif got_t.split(",") != want_targets:
                    failures.append(f"{where}: --targets {got_t} != rulesync.jsonc targets {','.join(want_targets)}")
                if got_f is None:
                    failures.append(
                        f"{where}: `rulesync generate` has no --features. Expected --features {','.join(want_features)}"
                    )
                elif got_f.split(",") != want_features:
                    failures.append(f"{where}: --features {got_f} != rulesync.jsonc features {','.join(want_features)}")
            else:
                got_p = flag_value(tokens, "--path", "--path")
                assertions += 1
                if got_p is None:
                    failures.append(
                        f"{where}: `rulesync fetch` has no --path .rulesync; the fetch 404s on rules/ and returns zero files"
                    )
                elif got_p.rstrip("/") != ".rulesync":
                    failures.append(f"{where}: `rulesync fetch` --path {got_p} != .rulesync")

# Every step that runs `rulesync fetch` authenticates. Read with yq per step,
# because the token is the step's env:, not part of the command line.
for path in files:
    # One "step=<token>" line per fetch step, so a step with no token is a
    # line with an empty value rather than no line at all. The version suffix
    # is required (tool-pins enforces it), which keeps a step that only
    # mentions "rulesync fetch" in an error message out of the match.
    tokens = yq(
        '[.jobs[].steps[] | select(.run // "" | test("rulesync@\\S+ fetch"))'
        ' | "step=" + ((.env.GITHUB_TOKEN // .env.GH_TOKEN // "") | tostring)] | join("\\n")',
        path,
    )
    for line in tokens.splitlines():
        value = line.removeprefix("step=")
        assertions += 1
        if value.strip() in ("", "null"):
            failures.append(
                f"{path}: a `rulesync fetch` step binds neither GITHUB_TOKEN nor GH_TOKEN in env:; "
                "unauthenticated fetches hit the shared anonymous API rate limit"
            )

# Non-vacuous: the extractor must find the shipped sync workflow's commands.
assertions += 1
if counts["generate"] == 0 or counts["fetch"] == 0:
    failures.append(
        f"extractor found {counts['fetch']} fetch and {counts['generate']} generate invocation(s) across "
        f"{len(files)} file(s); expected at least one of each (reusable-sync-ai-rules.yml)"
    )

if failures:
    for f in failures:
        print(f"FAIL: {NAME}: {f}", file=sys.stderr)
    sys.exit(1)
print(f"scanned {len(files)} workflow file(s): {counts['fetch']} fetch, {counts['generate']} generate invocation(s)")
print(f"PASS: {NAME} ({assertions} assertion(s))")
PY

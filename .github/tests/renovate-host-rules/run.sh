#!/usr/bin/env bash
# renovate-host-rules — reusable-renovate.yml builds RENOVATE_HOST_RULES with
# jq, and adds an api.anthropic.com rule only when ANTHROPIC_API_KEY is set
# (#135).
#
# The shipped `Build Renovate host rules` step is extracted with yq and run
# against fixtures under the shell Actions uses for `run:` (bash -e -o
# pipefail), with $GITHUB_ENV pointed at a scratch file:
#   - secret unset or empty: the value is byte-identical to the ghcr.io-only
#     rule the workflow used to paste inline;
#   - secret set: a second rule for api.anthropic.com carries the key as
#     `token` (Renovate sends `Authorization: Bearer <token>`) and the shipped
#     `anthropic-version` header;
#   - a key or registry token holding `"`, `\` or a newline still yields one
#     $GITHUB_ENV line of valid JSON that round-trips the value exactly.
# Structural checks: the secret is declared optional and bound from
# secrets.ANTHROPIC_API_KEY, the run body holds no `${{`, the step runs before
# the Renovate action, and that action's own env: does not set
# RENOVATE_HOST_RULES (a step env: overrides a $GITHUB_ENV value).
#
# Requires bash, jq, python3 (stdlib only) and yq (mikefarah v4).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

command -v yq >/dev/null || { echo "FAIL: renovate-host-rules: yq is required" >&2; exit 1; }
command -v jq >/dev/null || { echo "FAIL: renovate-host-rules: jq is required" >&2; exit 1; }

python3 - <<'PY'
import json, os, re, subprocess, sys, tempfile

NAME = "renovate-host-rules"
WF = ".github/workflows/reusable-renovate.yml"
STEP = "Build Renovate host rules"
failures, assertions = [], 0


def check(cond, msg):
    global assertions
    assertions += 1
    if not cond:
        failures.append(msg)


def yq_json(expr):
    out = subprocess.run(["yq", "-o=json", "-I=0", expr, WF],
                         check=True, capture_output=True, text=True).stdout
    return json.loads(out)


def finish():
    if failures:
        for f in failures:
            print(f"FAIL: {NAME}: {f}")
        print(f"FAIL: {NAME}: {len(failures)} of {assertions} assertion(s) failed")
        sys.exit(1)
    print(f"PASS: {NAME} ({assertions} assertion(s))")
    sys.exit(0)


secret = yq_json(".on.workflow_call.secrets.ANTHROPIC_API_KEY")
check(isinstance(secret, dict), "workflow_call does not declare an ANTHROPIC_API_KEY secret")
check(isinstance(secret, dict) and secret.get("required") is False,
      "the ANTHROPIC_API_KEY secret must be declared required: false")

steps = yq_json(".jobs.renovate.steps")
names = [s.get("name") for s in steps]
idx = names.index(STEP) if STEP in names else -1
check(idx >= 0, f"no step named '{STEP}' in jobs.renovate")
if idx < 0:
    finish()
step = steps[idx]
body = step.get("run", "")
env = step.get("env", {}) or {}

renovate_idx = [i for i, s in enumerate(steps)
                if str(s.get("uses", "")).startswith("renovatebot/github-action@")]
check(len(renovate_idx) == 1, f"expected one renovatebot/github-action step, found {len(renovate_idx)}")
if renovate_idx:
    r = steps[renovate_idx[0]]
    check(idx < renovate_idx[0], f"'{STEP}' must run before the Renovate action")
    check("RENOVATE_HOST_RULES" not in (r.get("env") or {}),
          "the Renovate step's env: sets RENOVATE_HOST_RULES, which overrides the $GITHUB_ENV value")

check("${{" not in body, f"'{STEP}' run body contains ${{{{ }}}}; bind values through env:")
check(env.get("ANTHROPIC_API_KEY", "").replace(" ", "") == "${{secrets.ANTHROPIC_API_KEY}}",
      "ANTHROPIC_API_KEY must be bound from secrets.ANTHROPIC_API_KEY")
check(env.get("REGISTRY_TOKEN", "").replace(" ", "")
      == "${{inputs.app-id!=''&&steps.app-token.outputs.token||secrets.GITHUB_TOKEN}}",
      "REGISTRY_TOKEN must be the App token when app-id is set, else GITHUB_TOKEN")
version = str(env.get("ANTHROPIC_VERSION", ""))
check(re.fullmatch(r"\d{4}-\d{2}-\d{2}", version) is not None,
      f"ANTHROPIC_VERSION must be a YYYY-MM-DD API version, got '{version}'")

tmp = tempfile.mkdtemp()
script = os.path.join(tmp, "step.sh")
with open(script, "w") as fh:
    fh.write(body)


def run_step(registry_token, api_key):
    """Run the shipped body; return (exit code, $GITHUB_ENV lines, stderr)."""
    genv = os.path.join(tmp, "github_env")
    open(genv, "w").close()
    e = {"PATH": os.environ["PATH"], "GITHUB_ENV": genv,
         "REGISTRY_TOKEN": registry_token, "ANTHROPIC_VERSION": version}
    if api_key is not None:
        e["ANTHROPIC_API_KEY"] = api_key
    p = subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", script],
                       env=e, capture_output=True, text=True)
    with open(genv) as fh:
        lines = fh.read().splitlines()
    return p.returncode, lines, p.stderr


def rules_of(lines, label):
    """Parse the single RENOVATE_HOST_RULES= line, or record why not."""
    check(len(lines) == 1, f"{label}: expected one $GITHUB_ENV line, got {len(lines)}: {lines!r}")
    if len(lines) != 1:
        return None, None
    key, _, value = lines[0].partition("=")
    check(key == "RENOVATE_HOST_RULES", f"{label}: $GITHUB_ENV line sets '{key}', not RENOVATE_HOST_RULES")
    try:
        return value, json.loads(value)
    except json.JSONDecodeError as exc:
        check(False, f"{label}: RENOVATE_HOST_RULES is not valid JSON ({exc}): {value!r}")
        return value, None


TOKEN = "ghs_sampleRegistryToken123"
# The value the workflow pasted inline before #135, with TOKEN substituted.
LEGACY = ('[{"matchHost":"ghcr.io","hostType":"docker","username":"x-access-token",'
          f'"password":"{TOKEN}"}}]')
GHCR = {"matchHost": "ghcr.io", "hostType": "docker",
        "username": "x-access-token", "password": TOKEN}

for label, key in (("secret unset", None), ("secret empty", "")):
    rc, lines, err = run_step(TOKEN, key)
    check(rc == 0, f"{label}: step exited {rc}: {err.strip()}")
    raw, _ = rules_of(lines, label)
    check(raw == LEGACY, f"{label}: RENOVATE_HOST_RULES is not byte-identical to the ghcr.io-only rule: {raw!r}")

for label, key in (("plain key", "sk-ant-api03-sampleKey_0123456789"),
                   ("hostile key", 'sk-"quoted"\\back\nslash')):
    rc, lines, err = run_step(TOKEN, key)
    check(rc == 0, f"{label}: step exited {rc}: {err.strip()}")
    _, rules = rules_of(lines, label)
    if rules is None:
        continue
    check(isinstance(rules, list) and len(rules) == 2, f"{label}: expected 2 host rules, got {rules!r}")
    if not (isinstance(rules, list) and len(rules) == 2):
        continue
    check(rules[0] == GHCR, f"{label}: the ghcr.io rule changed: {rules[0]!r}")
    a = rules[1]
    check(a.get("matchHost") == "api.anthropic.com", f"{label}: second rule matchHost is {a.get('matchHost')!r}")
    check(a.get("token") == key, f"{label}: the API key did not round-trip as token")
    check(a.get("headers") == {"anthropic-version": version},
          f"{label}: headers must be exactly anthropic-version {version}, got {a.get('headers')!r}")
    check("hostType" not in a and "password" not in a and "username" not in a,
          f"{label}: the api.anthropic.com rule carries unexpected auth/hostType keys: {sorted(a)}")

hostile_token = 'tok"en\\with\nnewline'
rc, lines, err = run_step(hostile_token, None)
check(rc == 0, f"hostile registry token: step exited {rc}: {err.strip()}")
_, rules = rules_of(lines, "hostile registry token")
if rules is not None:
    check(rules == [dict(GHCR, password=hostile_token)],
          f"hostile registry token: did not round-trip: {rules!r}")

finish()
PY

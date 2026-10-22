#!/usr/bin/env bash
# Regression test for the inert `additional_permissions` tool lists (#55,
# #56) and the missing `actions: read` on reusable-claude-review.yml (ported
# with #66).
#
# Scans every workflow under .github/workflows/ that runs
# anthropics/claude-code-action and asserts two rules against the shipped
# YAML (parsed with yq, checked with python3 stdlib):
#
# (a) `additional_permissions` is a GitHub permissions map. After removing
#     `${{ ... }}` expressions, every non-blank line must be `<scope>: <level>`
#     with <scope> from GitHub's token-permission vocabulary and <level> one of
#     read/write/none. The action skips any line without a colon
#     (src/github/token.ts parseAdditionalPermissions), so a Claude tool list
#     there (`Read`, `Bash(git diff *)`, `mcp__...`) is silently inert. Tools
#     belong in `claude_args: --allowedTools`.
#
# (b) A step that can run in tag mode, or that allows `mcp__github_ci__*`
#     tools, needs `actions: read` on the job's GITHUB_TOKEN (job-level
#     `permissions:` if present, otherwise workflow-level). On a PR the action
#     probes github.token with listWorkflowRunsForRepo before starting the
#     github_ci MCP server and skips the server on a 403
#     (src/mcp/install-mcp-server.ts). `additional_permissions` cannot satisfy
#     this: it widens the App token, not github.token.
#     A step "can run in tag mode" when it sets `track_progress: true` (forces
#     tag mode on PR/issue events) or sets no `prompt` (mention mode), per
#     src/modes/detector.ts.
#
#     Exempt by that rule: the eight analysis workflows (reusable-a11y-*,
#     reusable-quality-*, reusable-security-*) and reusable-auto-fix.yml. They
#     pass a `prompt` without `track_progress`, so they run in agent mode, where
#     the CI server is only attempted when allowedTools names an
#     `mcp__github_ci__*` tool; none does, so no probe runs and `actions: read`
#     would be inert. If one of them later adds such a tool, rule (b) applies.
#
# Usage: .github/tests/claude-action-permissions/run.sh   (no arguments)
# Requires: yq (mikefarah v4), python3.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

command -v yq >/dev/null || { echo "FAIL: yq not found on PATH" >&2; exit 1; }
command -v python3 >/dev/null || { echo "FAIL: python3 not found on PATH" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

shopt -s nullglob
files=(.github/workflows/*.yml .github/workflows/*.yaml)
shopt -u nullglob

: > "$tmp/index.tsv"
for f in "${files[@]}"; do
  grep -q 'anthropics/claude-code-action' "$f" || continue
  out="$tmp/$(printf '%s' "$f" | tr '/' '_').json"
  yq -o=json '.' "$f" > "$out"
  # Independent text count of action steps, so a parse that finds nothing
  # cannot pass vacuously.
  n="$(grep -cE '^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*anthropics/claude-code-action' "$f" || true)"
  printf '%s\t%s\t%s\n' "$f" "$out" "$n" >> "$tmp/index.tsv"
done

python3 - "$tmp/index.tsv" <<'PY'
import json
import re
import sys

SCOPES = {
    "actions", "artifact-metadata", "attestations", "checks", "code-quality",
    "contents", "deployments", "discussions", "id-token", "issues", "models",
    "packages", "pages", "pull-requests", "repository-projects",
    "security-events", "statuses", "vulnerability-alerts",
}
LEVELS = {"read", "write", "none"}
EXPR = re.compile(r"\$\{\{.*?\}\}")
PAIR = re.compile(r"^([A-Za-z_-]+)\s*:\s*(\S+)$")

failures = []
assertions = 0
workflows = 0
steps_seen = 0


def truthy(v):
    return v is True or (isinstance(v, str) and v.strip().lower() == "true")


def actions_granted(perms):
    if isinstance(perms, str):
        return perms.strip() in ("read-all", "write-all")
    if isinstance(perms, dict):
        return str(perms.get("actions", "")).strip() in ("read", "write")
    return False


with open(sys.argv[1]) as fh:
    rows = [line.rstrip("\n").split("\t") for line in fh if line.strip()]

for path, jpath, text_count in rows:
    workflows += 1
    with open(jpath) as fh:
        wf = json.load(fh) or {}
    on = wf.get("on") or {}
    call = on.get("workflow_call") if isinstance(on, dict) else None
    inputs = (call or {}).get("inputs") or {}
    allowed_default = str((inputs.get("allowed_tools") or {}).get("default", ""))

    found = 0
    for job_id, job in (wf.get("jobs") or {}).items():
        perms = job.get("permissions", wf.get("permissions"))
        for idx, step in enumerate(job.get("steps") or []):
            if not str(step.get("uses", "")).startswith("anthropics/claude-code-action"):
                continue
            found += 1
            where = f"{path}: job '{job_id}' step '{step.get('name', idx)}'"
            w = step.get("with") or {}

            # (a) additional_permissions must be a permissions map.
            ap = w.get("additional_permissions")
            if ap is not None:
                for raw in str(ap).splitlines():
                    line = EXPR.sub("", raw).strip()
                    if not line:
                        continue
                    assertions += 1
                    m = PAIR.match(line)
                    scope = m.group(1).replace("_", "-") if m else None
                    if not m or scope not in SCOPES or m.group(2) not in LEVELS:
                        failures.append(
                            f"{where}: additional_permissions line {line!r} is not a "
                            f"'<permission>: <read|write|none>' pair; tool names belong "
                            f"in claude_args --allowedTools")

            # (b) tag-mode-capable or github_ci-using steps need actions: read.
            tag_capable = truthy(w.get("track_progress")) or not w.get("prompt")
            ci_tools = "mcp__github_ci" in (str(w.get("claude_args", "")) + allowed_default)
            if tag_capable or ci_tools:
                assertions += 1
                if not actions_granted(perms):
                    why = "track_progress: true" if truthy(w.get("track_progress")) else (
                        "no prompt (mention/tag mode)" if not w.get("prompt") else
                        "mcp__github_ci tools allowed")
                    failures.append(
                        f"{where}: {why}, but the job's GITHUB_TOKEN lacks 'actions: read' "
                        f"(the github_ci MCP server is skipped on a 403)")

    steps_seen += found
    assertions += 1
    if str(found) != text_count:
        failures.append(
            f"{path}: parsed {found} claude-code-action step(s) but the text has "
            f"{text_count} 'uses:' line(s); the scan missed a step")

assertions += 1
if workflows == 0 or steps_seen == 0:
    failures.append("no claude-code-action steps found; the scan is vacuous")

if failures:
    for f in failures:
        print(f"FAIL: {f}", file=sys.stderr)
    sys.exit(1)

print(f"PASS: claude-action-permissions ({assertions} assertion(s))")
PY

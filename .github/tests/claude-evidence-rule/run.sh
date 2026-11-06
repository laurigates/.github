#!/usr/bin/env bash
# Regression test for ForumViriumHelsinki/.github#199: the free-form Claude
# review bots reported valid Python 3.14 syntax (PEP 758 `except A, B:`) as a
# blocking SyntaxError, predicted from model knowledge with no tool or CI run
# behind it.
#
# Scans every reusable-*.yml step that runs anthropics/claude-code-action in
# tag mode (`track_progress: true`, or no `prompt`: the review and @-mention
# bots, whose output is free prose rather than a --json-schema report) and
# asserts against the shipped YAML:
#
# (a) The instructions the model receives (the step's `prompt` plus
#     `claude_args`, which carries `--system-prompt`) contain the evidence rule
#     (a blocker cites evidence from this run, otherwise it is a question) and
#     the CI rule (no parse claims from reading code; read the github_ci tools).
# (b) `claude_args`, with `${{ }}` expressions removed, holds no `$` or
#     backtick. The action parses it with shell-quote, which expands `$NAME`
#     inside double quotes to an empty string, so such text in --system-prompt
#     would silently vanish.
# (c) The default `allowed_tools` of a `track_progress` review job grants no
#     tool that executes PR-controlled code or an unpinned interpreter
#     (`python`, `uv`, `pytest`, `pre-commit`, `just`, `make`, `bun`, `node`):
#     the job holds a `pull-requests: write` token, and the runner Python is
#     not the version the repository declares, so a compile() there reproduces
#     the false SyntaxError with a tool result behind it.
#
# Usage: .github/tests/claude-evidence-rule/run.sh   (no arguments)
# Requires: yq (mikefarah v4), python3.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

command -v yq >/dev/null || { echo "FAIL: yq not found on PATH" >&2; exit 1; }
command -v python3 >/dev/null || { echo "FAIL: python3 not found on PATH" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

shopt -s nullglob
files=(.github/workflows/reusable-*.yml .github/workflows/reusable-*.yaml)
shopt -u nullglob

: > "$tmp/index.tsv"
for f in "${files[@]}"; do
  grep -Fq 'anthropics/claude-code-action' "$f" || continue
  out="$tmp/$(printf '%s' "$f" | tr '/' '_').json"
  yq -o=json '.' "$f" > "$out"
  printf '%s\t%s\n' "$f" "$out" >> "$tmp/index.tsv"
done

python3 - "$tmp/index.tsv" <<'PY'
import json
import re
import sys

# Phrases the model must receive. Each is matched case-sensitively against the
# step's prompt + claude_args.
REQUIRED = {
    "evidence rule": "evidence obtained in this run",
    "question fallback": "as a question, not a blocker",
    "no parse claims from reading": "Do not report syntax or parse errors from reading code",
    "CI as the source": "get_ci_status",
    "PEP 758 example": "PEP 758",
}
EXPR = re.compile(r"\$\{\{.*?\}\}", re.S)
FORBIDDEN_TOOL = re.compile(r"Bash\((python|python3|uv|uvx|pytest|pre-commit|just|make|bun|node)\b")

failures = []
assertions = 0
steps_seen = 0


def truthy(v):
    return v is True or (isinstance(v, str) and v.strip().lower() == "true")


with open(sys.argv[1]) as fh:
    rows = [line.rstrip("\n").split("\t") for line in fh if line.strip()]

for path, jpath in rows:
    with open(jpath) as fh:
        wf = json.load(fh) or {}
    on = wf.get("on") or {}
    call = on.get("workflow_call") if isinstance(on, dict) else None
    inputs = (call or {}).get("inputs") or {}

    for job_id, job in (wf.get("jobs") or {}).items():
        for idx, step in enumerate(job.get("steps") or []):
            if not str(step.get("uses", "")).startswith("anthropics/claude-code-action"):
                continue
            w = step.get("with") or {}
            track = truthy(w.get("track_progress"))
            if not (track or not w.get("prompt")):
                continue
            steps_seen += 1
            where = f"{path}: job '{job_id}' step '{step.get('name', idx)}'"
            prompt = str(w.get("prompt") or "")
            args = str(w.get("claude_args") or "")
            text = prompt + "\n" + args

            # (a) evidence and CI rules reach the model.
            for label, needle in REQUIRED.items():
                assertions += 1
                if needle not in text:
                    failures.append(f"{where}: instructions lack the {label} ({needle!r})")

            # (b) nothing in claude_args that shell-quote would expand away.
            assertions += 1
            bare = EXPR.sub("", args)
            if "$" in bare or "`" in bare:
                failures.append(
                    f"{where}: claude_args contains '$' or '`' outside ${{{{ }}}}; "
                    f"shell-quote drops $NAME inside double quotes")

            # (c) a track_progress review job grants no code-executing tool.
            if track:
                default = str((inputs.get("allowed_tools") or {}).get("default", ""))
                assertions += 1
                if not default:
                    failures.append(f"{where}: no allowed_tools default to check")
                m = FORBIDDEN_TOOL.search(default)
                if m:
                    failures.append(
                        f"{where}: allowed_tools default grants {m.group(0)}...), which runs "
                        f"PR-controlled code or an unpinned interpreter in a job holding "
                        f"pull-requests: write")

assertions += 1
if steps_seen == 0:
    failures.append("no tag-mode claude-code-action steps found; the scan is vacuous")

if failures:
    for f in failures:
        print(f"FAIL: {f}", file=sys.stderr)
    sys.exit(1)

print(f"PASS: claude-evidence-rule ({assertions} assertion(s))")
PY

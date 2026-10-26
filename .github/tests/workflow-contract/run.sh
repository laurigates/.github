#!/usr/bin/env bash
# Contract test for what this repo ships to other laurigates repos, and for the
# lint gate in front of it.
#
#   1. Every .github/workflows/reusable-*.{yml,yaml} is callable (`on`
#      includes workflow_call) and declares a top-level `permissions:` map, so
#      a caller never hands it more token scope than it asked for. GitHub
#      accepts both extensions for workflow files, so both are scanned.
#   2. The lint gate (.github/workflows/lint.yml) runs the discovery runner
#      `bash .github/tests/run.sh` in exactly one step that has no `if:` and
#      no `continue-on-error`, runs no single test on its own (the runner
#      already does, and a per-test step is how a new test got left out of
#      CI), pins every `uses:` to a full commit SHA with a version comment,
#      checks out with `persist-credentials: false`, and sets a job
#      `timeout-minutes`. The justfile's `test` recipe runs the same runner.
#   3. Every `uses: laurigates/.github/.github/workflows/<file>@<ref>` in a
#      tracked file (workflows, docs, rule sources) names a workflow that
#      exists here and declares workflow_call, and every
#      `uses: laurigates/.github/.github/actions/<name>@<ref>` names a
#      directory here holding an action.yml. The owner is matched
#      case-insensitively and the value may be quoted.
#
# Reads the shipped files directly with yq and python3 (both on ubuntu-slim).
# Every scan asserts it found something before its per-item checks, so an
# empty glob or a broken pattern fails instead of passing vacuously.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

command -v yq >/dev/null 2>&1 || { echo "FATAL: yq not on PATH" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not on PATH" >&2; exit 1; }

assertions=0
failures=0

pass() { assertions=$((assertions + 1)); }
fail() { assertions=$((assertions + 1)); failures=$((failures + 1)); echo "FAIL: $*"; }

# `on` may be a string, a list, or a map; all three forms are valid workflow
# syntax. yq converts it to JSON and python3 decides, which keeps the three
# cases readable.
is_callable() {
  yq -o=json '.on' "$1" 2>/dev/null | python3 -c '
import json, sys
on = json.load(sys.stdin)
ok = on == "workflow_call" if isinstance(on, str) else "workflow_call" in (on or [])
sys.exit(0 if ok else 1)'
}

shopt -s nullglob

# ------------------------------------------------------------ 1. reusables
reusables=(.github/workflows/reusable-*.yml .github/workflows/reusable-*.yaml)
if [ "${#reusables[@]}" -eq 0 ]; then
  fail "no .github/workflows/reusable-*.{yml,yaml} found (glob matched nothing)"
else
  pass
fi
for f in ${reusables[@]+"${reusables[@]}"}; do
  if is_callable "$f"; then pass; else fail "$f: \`on\` does not include workflow_call"; fi
  case "$(yq '.permissions | tag' "$f" 2>/dev/null || true)" in
    '!!map') pass ;;
    '!!str') fail "$f: top-level \`permissions:\` is the string '$(yq '.permissions' "$f")'; declare an explicit map of scopes" ;;
    *) fail "$f: no top-level \`permissions:\` map" ;;
  esac
done

# ------------------------------------------------------------ 2. lint gate
lint=.github/workflows/lint.yml
if [ ! -f "$lint" ]; then
  fail "$lint does not exist"
else
  pass
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT
  yq -o=json '.' "$lint" >"$tmp"
  out="$(python3 - "$tmp" 2>&1 <<'PY' || true
import json, re, sys
with open(sys.argv[1]) as fh:
    wf = json.load(fh) or {}
errs, n = [], 0
def check(cond, msg):
    global n
    n += 1
    if not cond:
        errs.append(msg)
jobs = wf.get("jobs") or {}
check(jobs, "no jobs")
runner_steps = 0
uses_seen = 0
for jid, job in jobs.items():
    check(job.get("timeout-minutes") is not None, f"job {jid!r} has no timeout-minutes")
    for i, step in enumerate(job.get("steps") or []):
        where = f"job {jid!r} step {step.get('name', i)!r}"
        run = str(step.get("run", ""))
        lines = [l.strip() for l in run.splitlines() if l.strip() and not l.strip().startswith("#")]
        if lines == ["bash .github/tests/run.sh"]:
            runner_steps += 1
            check("if" not in step, f"{where}: the test-runner step has an if:, so it can be skipped")
            check(not step.get("continue-on-error"), f"{where}: the test-runner step is continue-on-error, so it cannot fail the job")
        check(not re.search(r"\.github/tests/[^/\s]+/run\.sh", run),
              f"{where}: runs one test directly; .github/tests/run.sh already runs every test")
        uses = step.get("uses")
        if uses is None:
            continue
        uses_seen += 1
        check(re.fullmatch(r"[^@\s]+@[0-9a-f]{40}", str(uses)) is not None,
              f"{where}: uses {uses!r} is not pinned to a full commit SHA")
        if str(uses).startswith("actions/checkout@"):
            check(str((step.get("with") or {}).get("persist-credentials", "")).lower() == "false",
                  f"{where}: actions/checkout without persist-credentials: false")
check(runner_steps == 1, f"expected exactly one step running `bash .github/tests/run.sh`, found {runner_steps}")
check(uses_seen > 0, "no uses: steps found (expected at least actions/checkout)")
for e in errs:
    print(e)
print(f"COUNT {n} {len(errs)}")
PY
  )"
  # The python block reports every failed check, then `COUNT <checks> <failed>`.
  # A missing COUNT line means it crashed, which must not read as a pass.
  count="$(sed -n 's/^COUNT \([0-9]*\) \([0-9]*\)$/\1 \2/p' <<<"$out")"
  if [ -z "$count" ]; then
    fail "$lint: the lint-gate check crashed: $out"
  else
    read -r n_checks n_failed <<<"$count"
    while IFS= read -r line; do
      case "$line" in COUNT*|'') ;; *) echo "FAIL: $lint: $line" ;; esac
    done <<<"$out"
    assertions=$((assertions + n_checks))
    failures=$((failures + n_failed))
  fi
  # Every pinned `uses:` line carries a `# vX` comment saying what the SHA is.
  bad="$(grep -nE '^[[:space:]]*(-[[:space:]]+)?uses:' "$lint" | grep -vE '@[0-9a-f]{40}[[:space:]]+#[[:space:]]*v[0-9]' || true)"
  if [ -z "$bad" ]; then pass; else fail "$lint: uses: line(s) without a '# vX.Y.Z' comment after the SHA: $bad"; fi
fi
# The justfile's `test` recipe runs the same runner.
recipe="$(awk '/^test( |:)/{f=1; print; next} f && /^[^[:space:]]/{f=0} f' justfile)"
if grep -Eq '^test[[:space:]]+\*names[[:space:]]*:' <<<"$recipe" && grep -Fq 'bash .github/tests/run.sh "$@"' <<<"$recipe"; then
  pass
else
  fail "justfile: no \`test *names:\` recipe running \`bash .github/tests/run.sh \"\$@\"\`"
fi

# ------------------------------------------------------------ 3. uses: refs
# [A-Za-z0-9._-]+ excludes doc placeholders such as `reusable-<name>.yml`. -i
# because GitHub resolves owner/repo case-insensitively; the optional quote
# covers `uses: "…"` and `uses: '…'`.
refs="$(git grep -hoiE 'uses:[[:space:]]*["'"'"']?laurigates/\.github/\.github/workflows/[A-Za-z0-9._-]+@[A-Za-z0-9._/-]+' \
  | sed -E 's#.*/workflows/([^@]+)@.*#\1#' | LC_ALL=C sort -u || true)"
if [ -z "$refs" ]; then
  fail "found no 'uses: laurigates/.github/.github/workflows/<file>@<ref>' references (pattern or git grep broken)"
else
  pass
fi
while IFS= read -r name; do
  [ -n "$name" ] || continue
  target=".github/workflows/$name"
  if [ ! -f "$target" ]; then
    where="$(git grep -liE "workflows/${name//./\\.}@" | tr '\n' ' ' || true)"
    fail "uses: …/workflows/$name points at a file that does not exist (referenced in: $where)"
  elif ! is_callable "$target"; then
    fail "uses: …/workflows/$name points at a workflow that does not declare workflow_call"
  else
    pass
  fi
done <<EOF
$refs
EOF

actions="$(git grep -hoiE 'uses:[[:space:]]*["'"'"']?laurigates/\.github/\.github/actions/[A-Za-z0-9._-]+@[A-Za-z0-9._/-]+' \
  | sed -E 's#.*/actions/([^@]+)@.*#\1#' | LC_ALL=C sort -u || true)"
if [ -z "$actions" ]; then
  fail "found no 'uses: laurigates/.github/.github/actions/<name>@<ref>' references (pattern or git grep broken)"
else
  pass
fi
while IFS= read -r name; do
  [ -n "$name" ] || continue
  if [ -f ".github/actions/$name/action.yml" ] || [ -f ".github/actions/$name/action.yaml" ]; then
    pass
  else
    fail "uses: …/actions/$name points at a directory with no action.yml"
  fi
done <<EOF
$actions
EOF

if [ "$failures" -gt 0 ]; then
  echo "FAIL: workflow-contract ($failures of $assertions assertion(s) failed)"
  exit 1
fi
echo "PASS: workflow-contract ($assertions assertion(s))"

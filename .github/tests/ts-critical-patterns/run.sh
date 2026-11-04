#!/usr/bin/env bash
# ts-critical-patterns: the deterministic pre-step of
# reusable-quality-typescript.yml (laurigates/.github#83).
#
# The grep-able Critical tier (explicit any, @ts-ignore, a bare
# @ts-expect-error, @ts-nocheck, plain non-null assertions) is reported by a
# shell step instead of Claude. This test extracts the shipped `run:` body of
# step `tscritical` with yq and runs it in a scratch repository against
# fixture files, then checks:
#   - every pattern is reported at the right file and line, and the
#     negatives (`!==`, `!x`, an explained @ts-expect-error, `company`, a
#     comment line) are not;
#   - a deleted file, a symlink and a non-matching extension are skipped;
#   - a path with `%`, `,`, `:` or a newline is escaped in the annotation;
#   - $GITHUB_OUTPUT holds exactly the fixed keys with the right counts;
#   - the annotation cap and its notice;
#   - the step is wired: id, env bindings, no `${{` in the body, the job's
#     `any` output reads it, and the prompt no longer lists the tier.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

WF="${1:-.github/workflows/reusable-quality-typescript.yml}"
N=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { N=$((N + 1)); }
eq() { [ "$1" = "$2" ] || fail "$3: expected [$2], got [$1]"; ok; }
has() { grep -Fxq -- "$2" "$1" || { echo "--- $1:" >&2; cat "$1" >&2; fail "$3: missing line [$2]"; }; ok; }
hasnt() { if grep -Fq -- "$2" "$1"; then fail "$3: unexpected [$2]"; fi; ok; }

command -v yq >/dev/null 2>&1 || fail "yq (mikefarah v4) is not on PATH"
[ -f "$WF" ] || fail "$WF not found"

STEP='[.jobs.*.steps[] | select(.id == "tscritical")]'
eq "$(yq "$STEP | length" "$WF")" 1 "exactly one step with id tscritical"
sel() { yq -r "$STEP | .[0] | $1" "$WF"; }

# ---- wiring -----------------------------------------------------------------
BODY="$(sel .run)"
[ -n "$BODY" ] && [ "$BODY" != null ] || fail "tscritical has no run: body"
ok
if grep -Fq '${{' <<<"$BODY"; then fail 'tscritical run: body contains ${{ (bind values through env:)'; fi
ok
eq "$(sel .if)" "steps.event.outputs.supported == 'true' && steps.actor.outputs.allowed == 'true'" "tscritical if:"
eq "$(sel .env.EVENT_NAME)" '${{ github.event_name }}' "env EVENT_NAME"
eq "$(sel .env.BASE_REF)" '${{ github.base_ref }}' "env BASE_REF"
eq "$(sel .env.FILE_PATTERNS)" '${{ inputs.file-patterns }}' "env FILE_PATTERNS"
eq "$(sel .env.GIT_GLOB_PATHSPECS)" '1' "env GIT_GLOB_PATHSPECS"
eq "$(yq -r '.jobs.analyze.outputs.any' "$WF")" '${{ steps.tscritical.outputs.any_count }}' "job output any"
# The step must run before the analysis, so its findings exist even when
# Claude is skipped or fails.
ORDER="$(yq -r '[.jobs.analyze.steps[] | (.id // "")] | to_entries | map(select(.value == "changed" or .value == "tscritical" or .value == "analyze")) | map(.value) | join(",")' "$WF")"
eq "$ORDER" "changed,tscritical,analyze" "step order"
PROMPT="$(yq -r '.jobs.analyze.steps[] | select(.id == "analyze") | .with.prompt' "$WF")"
if grep -Fq '## Critical Issues' <<<"$PROMPT"; then fail "prompt still lists the Critical tier"; fi
ok
grep -Fq 'must not report or count them' <<<"$PROMPT" || fail "prompt does not tell Claude to leave the deterministic patterns alone"
ok

# ---- fixture repository -----------------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
printf '%s\n' "$BODY" > "$TMP/step.sh"
R="$TMP/repo"
mkdir -p "$R/src"
git -C "$R" init -q -b main
git -C "$R" config user.email t@example.invalid
git -C "$R" config user.name t
printf 'const gone: any = 1;\n' > "$R/src/gone.ts"
printf 'x\n' > "$R/README.md"
git -C "$R" add -A
git -C "$R" commit -qm base
git -C "$R" update-ref refs/remotes/origin/main HEAD

cat > "$R/src/any.ts" <<'TS'
const a: any = 1;
const b = x as any;
const c = <any>y;
const company = 1; const anyway = 2;
// @ts-ignore
// @ts-expect-error
// @ts-expect-error -- reason here
const d = user!.name;
if (a !== b && !c) {}
foo(arr!)
const e = m!['k'];
// note: any value works
TS
printf '// @ts-nocheck\n/* @ts-expect-error */\nlet ok = 1;\n' > "$R/src/nocheck.tsx"
printf 'let q: any;\n' > "$R/src/100%.ts"
printf 'let r = s!.t;\n' > "$R/src/new
line.ts"
printf 'let u: any;\n' > "$R/src/a,b:c.ts"
printf 'let v: any;\n' > "$R/src/skip.js"
ln -s any.ts "$R/src/link.ts"
git -C "$R" rm -q src/gone.ts
git -C "$R" add -A
git -C "$R" commit -qm head

# run <annotation limit or ''> : runs the extracted step in the fixture repo
run() {
  local out="$TMP/run"
  rm -rf "$out"; mkdir -p "$out"
  (
    cd "$R"
    if [ -n "$1" ]; then export ANNOTATION_LIMIT="$1"; else unset ANNOTATION_LIMIT; fi
    EVENT_NAME=pull_request BASE_REF=main FILE_PATTERNS='**/*.ts **/*.tsx' GIT_GLOB_PATHSPECS=1 \
      RUNNER_TEMP="$out" GITHUB_OUTPUT="$out/out" GITHUB_STEP_SUMMARY="$out/summary" \
      bash "$TMP/step.sh" > "$out/stdout" 2> "$out/stderr"
  ) || { cat "$out/stdout" "$out/stderr" >&2; fail "step exited non-zero"; }
}

run 100
S="$TMP/run/stdout"
has "$S" '::warning file=src/any.ts,line=1,title=Explicit any::Explicit `any` disables type checking for this value. Use a concrete type or `unknown`.' "colon any"
has "$S" '::warning file=src/any.ts,line=2,title=Explicit any::Explicit `any` disables type checking for this value. Use a concrete type or `unknown`.' "as any"
has "$S" '::warning file=src/any.ts,line=3,title=Explicit any::Explicit `any` disables type checking for this value. Use a concrete type or `unknown`.' "<any>"
has "$S" '::warning file=src/any.ts,line=5,title=@ts-ignore::`@ts-ignore` suppresses every error on the next line. Fix the error, or use `@ts-expect-error -- <reason>`.' "ts-ignore"
has "$S" '::warning file=src/any.ts,line=6,title=Bare @ts-expect-error::`@ts-expect-error` has no explanation. Add the reason after the directive.' "bare expect-error"
has "$S" '::warning file=src/any.ts,line=8,title=Non-null assertion::Non-null assertion `!` skips the null check. Guard the value or narrow its type.' "x!."
has "$S" '::warning file=src/any.ts,line=10,title=Non-null assertion::Non-null assertion `!` skips the null check. Guard the value or narrow its type.' "x!)"
has "$S" '::warning file=src/any.ts,line=11,title=Non-null assertion::Non-null assertion `!` skips the null check. Guard the value or narrow its type.' "x!["
has "$S" '::warning file=src/nocheck.tsx,line=1,title=@ts-nocheck::`@ts-nocheck` turns off type checking for the whole file. Remove it and fix the errors.' "ts-nocheck"
has "$S" '::warning file=src/nocheck.tsx,line=2,title=Bare @ts-expect-error::`@ts-expect-error` has no explanation. Add the reason after the directive.' "bare block expect-error"
has "$S" '::warning file=src/100%25.ts,line=1,title=Explicit any::Explicit `any` disables type checking for this value. Use a concrete type or `unknown`.' "percent escaped"
has "$S" '::warning file=src/new%0Aline.ts,line=1,title=Non-null assertion::Non-null assertion `!` skips the null check. Guard the value or narrow its type.' "newline escaped"
has "$S" '::warning file=src/a%2Cb%3Ac.ts,line=1,title=Explicit any::Explicit `any` disables type checking for this value. Use a concrete type or `unknown`.' "comma and colon escaped"
for l in 4 7 9 12; do hasnt "$S" "file=src/any.ts,line=$l," "negative on line $l"; done
hasnt "$S" "nocheck.tsx,line=3," "plain line"
hasnt "$S" "gone.ts" "deleted file"
hasnt "$S" "link.ts" "symlink"
hasnt "$S" "skip.js" "non-matching extension"
eq "$(grep -c '^::warning ' "$S")" 13 "warning count"
hasnt "$S" "::notice::" "no cap notice under the limit"
# Every stdout line is one workflow command: an unescaped newline in a path
# would split one into two.
eq "$(grep -vc '^::' "$S" || true)" 0 "every stdout line is a workflow command"

O="$TMP/run/out"
eq "$(cut -d= -f1 "$O" | sort | tr '\n' ' ')" "any_count critical_count hits " "output keys"
has "$O" "any_count=5" "any_count"
has "$O" "critical_count=13" "critical_count"
has "$O" "hits=true" "hits"
grep -Fq '| `src/any.ts` | 1 | Explicit any |' "$TMP/run/summary" || fail "summary row"
ok
grep -Fq 'src/new line.ts' "$TMP/run/summary" || fail "summary does not flatten a newline in a path"
ok

# Default cap: 10 annotations, the rest named in a notice.
run ''
eq "$(grep -c '^::warning ' "$TMP/run/stdout")" 10 "default annotation cap"
has "$TMP/run/stdout" "::notice::TypeScript critical patterns: 3 further hit(s) appear in the job summary only." "cap notice"
eq "$(grep -c '^| `' "$TMP/run/summary")" 13 "summary lists every hit"

# No matching file: zero counts, no annotation, success.
git -C "$R" update-ref refs/remotes/origin/main HEAD
run 100
eq "$(grep -c '^::' "$TMP/run/stdout" || true)" 0 "no annotation without files"
has "$TMP/run/out" "any_count=0" "zero any_count"
has "$TMP/run/out" "critical_count=0" "zero critical_count"
has "$TMP/run/out" "hits=false" "hits false"

# An unreadable range is an internal error, not a clean result.
git -C "$R" update-ref -d refs/remotes/origin/main
if ( cd "$R" && EVENT_NAME=pull_request BASE_REF=main FILE_PATTERNS='**/*.ts' GIT_GLOB_PATHSPECS=1 \
       RUNNER_TEMP="$TMP" GITHUB_OUTPUT="$TMP/x" GITHUB_STEP_SUMMARY="$TMP/y" bash "$TMP/step.sh" >/dev/null 2>&1 ); then
  fail "step passed with a missing base ref"
fi
ok

echo "PASS: ts-critical-patterns ($N assertion(s))"

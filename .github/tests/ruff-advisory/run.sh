#!/usr/bin/env bash
# ruff-advisory: the advisory ruff step of reusable-quality-code-smell.yml
# (laurigates/.github#96).
#
# Python smells a linter finds deterministically are reported by ruff
# instead of Claude, and the prompt lists the same rule ids as not to
# report. This test extracts the shipped `run:` body of step `ruff` with yq
# and runs it in a scratch repository, with a stub curl serving a tarball
# that holds a stub ruff. The stub replays ruff-output.json, the output of
# the real ruff release the workflow pins (gen.sh records it; the version is
# in the file), filtered to the files it is given, as ruff would. It checks:
#   - the step's RUFF_SELECT and the prompt's list of ruff ids are the same
#     set, and the prompt states the thresholds the step pins;
#   - hits in changed .py files are annotated; a changed file without hits,
#     an unchanged file with hits, a deleted file, a symlink and a non-.py
#     file are not, and only the changed .py files reach ruff;
#   - a parse error (`invalid-syntax`) is not reported as a hit;
#   - paths and messages with %, CR, LF, `,` or `:` are escaped, a pipe in a
#     summary cell is escaped, a leading dash reaches ruff after `--`, and
#     every stdout line is one command;
#   - a record for a path outside the checkout is dropped, against a control
#     record inside it that is reported;
#   - ruff runs with exactly the three pinned --config values;
#   - $GITHUB_OUTPUT holds exactly the fixed keys with numeric counts;
#   - the annotation cap and its notice;
#   - no download without a changed .py file; a checksum mismatch and an
#     unreadable pull-request range fail; a failed download, a ruff crash,
#     non-JSON output and a non-zero exit with valid JSON warn and stay
#     green, with ruff's stderr fenced by stop-commands;
#   - workflow_dispatch diffs HEAD~1, and with no HEAD~1 scans nothing;
#   - the step is wired: id, if:, env bindings, no `${{` in the body, and it
#     runs between the `changed` step and the analysis.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

WF="${1:-.github/workflows/reusable-quality-code-smell.yml}"
HERE=.github/tests/ruff-advisory
FIXTURE="$PWD/$HERE/ruff-output.json"
N=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { N=$((N + 1)); }
eq() { [ "$1" = "$2" ] || fail "$3: expected [$2], got [$1]"; ok; }
has() { grep -Fxq -- "$2" "$1" || { echo "--- $1:" >&2; cat "$1" >&2; fail "$3: missing line [$2]"; }; ok; }
hasnt() { if grep -Fq -- "$2" "$1"; then fail "$3: unexpected [$2]"; fi; ok; }

command -v yq >/dev/null 2>&1 || fail "yq (mikefarah v4) is not on PATH"
[ -f "$WF" ] || fail "$WF not found"
[ -f "$FIXTURE" ] || fail "$FIXTURE not found"
# shellcheck source=layout.sh
. "$HERE/layout.sh"

STEP='[.jobs.*.steps[] | select(.id == "ruff")]'
eq "$(yq "$STEP | length" "$WF")" 1 "exactly one step with id ruff"
sel() { yq -r "$STEP | .[0] | $1" "$WF"; }

# ---- wiring -----------------------------------------------------------------
BODY="$(sel .run)"
[ -n "$BODY" ] && [ "$BODY" != null ] || fail "ruff has no run: body"
ok
if grep -Fq '${{' <<<"$BODY"; then fail 'ruff run: body contains ${{ (bind values through env:)'; fi
ok
eq "$(sel .if)" "steps.event.outputs.supported == 'true' && steps.actor.outputs.allowed == 'true'" "ruff if:"
eq "$(sel .env.EVENT_NAME)" '${{ github.event_name }}' "env EVENT_NAME"
eq "$(sel .env.BASE_REF)" '${{ github.base_ref }}' "env BASE_REF"
eq "$(sel .env.FILE_PATTERNS)" '${{ inputs.file-patterns }}' "env FILE_PATTERNS"
eq "$(sel .env.GIT_GLOB_PATHSPECS)" '1' "env GIT_GLOB_PATHSPECS"
eq "$(sel '.continue-on-error // "unset"')" unset "ruff step has no continue-on-error"
VERSION="$(sel .env.RUFF_VERSION)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "RUFF_VERSION [$VERSION] is not one exact version"
ok
[[ "$(sel .env.RUFF_SHA256)" =~ ^[0-9a-f]{64}$ ]] || fail "RUFF_SHA256 is not a sha256"
ok
# The recorded output must come from the version the workflow pins.
eq "$(jq -r .ruff_version "$FIXTURE")" "$VERSION" "fixture recorded with the pinned ruff"
ORDER="$(yq -r '[.jobs.analyze.steps[] | (.id // "")] | map(select(. == "changed" or . == "ruff" or . == "analyze")) | join(",")' "$WF")"
eq "$ORDER" "changed,ruff,analyze" "step order"
# The analysis must not depend on the ruff step: its if: names no ruff output.
if yq -r '.jobs.analyze.steps[] | select(.id == "analyze") | .if' "$WF" | grep -Fq 'steps.ruff' ; then
  fail "the analysis is gated on the ruff step"
fi
ok

# ---- the contract: RUFF_SELECT equals the prompt's list ---------------------
SELECT="$(sel .env.RUFF_SELECT)"
[[ "$SELECT" =~ ^[A-Z]+[0-9]+(,[A-Z]+[0-9]+)*$ ]] || fail "RUFF_SELECT [$SELECT] is not a comma-separated id list"
ok
PROMPT="$(yq -r '.jobs.analyze.steps[] | select(.id == "analyze") | .with.prompt' "$WF")"
# The block runs from the line naming the ruff step to the next blank line.
BLOCK="$(awk '/^The workflow.s ruff step already reports/ { on = 1 } on && /^$/ { exit } on' <<<"$PROMPT")"
[ -n "$BLOCK" ] || fail "prompt has no ruff block"
ok
grep -Fq 'you must not report or count what they cover' <<<"$BLOCK" || fail "prompt does not tell Claude to leave the ruff ids alone"
ok
STEP_IDS="$(tr ',' '\n' <<<"$SELECT" | LC_ALL=C sort)"
PROMPT_IDS="$(grep -oE '`[A-Z]+[0-9]+`' <<<"$BLOCK" | tr -d '`' | LC_ALL=C sort -u)"
eq "$PROMPT_IDS" "$STEP_IDS" "prompt ruff ids equal RUFF_SELECT"
eq "$(tr ',' '\n' <<<"$SELECT" | LC_ALL=C sort | uniq -d)" "" "RUFF_SELECT has no duplicate"
# Thresholds: the prompt states what the step pins.
grep -Fq -- "--config 'lint.mccabe.max-complexity = 10'" <<<"$BODY" || fail "step does not pin max-complexity 10"
ok
grep -Fq 'cyclomatic complexity over 10' <<<"$BLOCK" || fail "prompt does not state complexity over 10"
ok
grep -Fq -- "--config 'lint.pylint.max-args = 4'" <<<"$BODY" || fail "step does not pin max-args 4"
ok
grep -Fq 'more than 4 parameters' <<<"$BLOCK" || fail "prompt does not state more than 4 parameters"
ok
# TD003 reports TODO, FIXME and XXX (the fixture records all three), so the
# prompt must name all three.
grep -Fq '`TD003`: a TODO, FIXME or XXX comment' <<<"$BLOCK" || fail "prompt does not name the three tags TD003 reports"
ok
grep -Fq -- '--isolated' <<<"$BODY" || fail "step does not ignore the caller's ruff configuration"
ok

# ---- fixture repository -----------------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
printf '%s\n' "$BODY" > "$TMP/step.sh"

# Stub ruff: logs its argv, then replays the recorded output for the files
# it was given. STUB_RUFF_MODE=crash prints a workflow command to stderr and
# exits 2; =garbage prints text that is not JSON; =jsonfail prints the replay,
# valid JSON, and exits 2. STUB_RUFF_EXTRA names a JSON array of records
# appended to the replay unfiltered, with @ROOT@ in a filename replaced by
# the checkout, so a record whose path the step was not given reaches it.
PKG="$TMP/pkg/ruff-x86_64-unknown-linux-gnu"
mkdir -p "$PKG"
cat > "$PKG/ruff" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'STUB-RUFF-RAN\n' >> "$STUB_LOG/ruff-ran"
printf '%s\0' "$@" >> "$STUB_LOG/ruff-argv"
case "${STUB_RUFF_MODE:-}" in
  crash) echo '::error::injected from ruff stderr' >&2; exit 2 ;;
  garbage) echo 'not json'; exit 0 ;;
esac
files=()
seen=false
for a in "$@"; do
  if $seen; then files+=("$a"); elif [ "$a" = "--" ]; then seen=true; fi
done
root="$(pwd -P)/"
extra="${STUB_RUFF_EXTRA:-/dev/null}"
printf '%s\0' "${files[@]}" | jq -sR --arg root "$root" --slurpfile fx "$STUB_RUFF_FIXTURE" --slurpfile extra "$extra" '
  (split("\u0000") | map(select(length > 0)) | map($root + .)) as $files
  | [$fx[0].output[] | .filename |= sub("^@ROOT@/"; $root) | select(.filename as $f | $files | index([$f]))]
    + [($extra[0] // [])[] | .filename |= sub("^@ROOT@/"; $root)]'
if [ "${STUB_RUFF_MODE:-}" = jsonfail ]; then exit 2; fi
SH
chmod +x "$PKG/ruff"
tar -czf "$TMP/good.tgz" -C "$TMP/pkg" ruff-x86_64-unknown-linux-gnu
GOOD_SHA="$(sha256sum "$TMP/good.tgz" | cut -d' ' -f1)"

# Stub curl: logs the URL, writes the tarball to -o. STUB_CURL_FAIL=1 fails.
mkdir -p "$TMP/stubs"
cat > "$TMP/stubs/curl" <<'SH'
#!/usr/bin/env bash
out=''; url=''
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac; done
printf '%s\n' "$url" >> "$STUB_LOG/curl-urls"
if [ "${STUB_CURL_FAIL:-}" = 1 ]; then exit 22; fi
cp "$STUB_TARBALL" "$out"
SH
chmod +x "$TMP/stubs/curl"
[ -x "$TMP/stubs/curl" ] && [ -x "$PKG/ruff" ] || fail "stubs are not executable"
ok

R="$TMP/repo"
mkdir -p "$R"
git -C "$R" init -q -b main
git -C "$R" config user.email t@example.invalid
git -C "$R" config user.name t
layout_base "$R"
printf 'print(0)\n' > "$R/gone.py"
git -C "$R" add -A
git -C "$R" commit -qm base
git -C "$R" update-ref refs/remotes/origin/main HEAD
layout_head "$R"
printf 'print(9)\n' > "$R/src/skip.js"
ln -s hits.py "$R/src/link.py"
git -C "$R" rm -q gone.py
git -C "$R" add -A
git -C "$R" commit -qm head

# run <dir> <expect exit> [VAR=value ...]: runs the extracted step in <dir>
# with the stubs, in a fresh $TMP/run.
run() {
  local dir="$1" want="$2" rc=0
  shift 2
  local out="$TMP/run"
  rm -rf "$out"; mkdir -p "$out/log"
  (
    cd "$dir"
    export PATH="$TMP/stubs:$PATH" STUB_LOG="$out/log" STUB_TARBALL="$TMP/good.tgz" STUB_RUFF_FIXTURE="$FIXTURE"
    export EVENT_NAME=pull_request BASE_REF=main FILE_PATTERNS='**/*.py **/*.js' GIT_GLOB_PATHSPECS=1
    export RUFF_VERSION="$VERSION" RUFF_SHA256="$GOOD_SHA" RUFF_SELECT="$SELECT" ANNOTATION_LIMIT=100
    export RUNNER_TEMP="$out" GITHUB_OUTPUT="$out/out" GITHUB_STEP_SUMMARY="$out/summary"
    for kv in "$@"; do export "${kv?}"; done
    bash "$TMP/step.sh" > "$out/stdout" 2> "$out/stderr"
  ) || rc=$?
  [ "$rc" = "$want" ] || { cat "$out/stdout" "$out/stderr" >&2; fail "step exited $rc, expected $want ($*)"; }
}
S="$TMP/run/stdout"
O="$TMP/run/out"
W='::warning file='

run "$R" 0
[ -s "$TMP/run/log/ruff-ran" ] || fail "the stub ruff did not run"
ok
has "$TMP/run/log/curl-urls" "https://github.com/astral-sh/ruff/releases/download/$VERSION/ruff-x86_64-unknown-linux-gnu.tar.gz" "download URL"
# Only the changed .py files reach ruff, after `--`.
ARGS="$(tr '\0' '\n' < "$TMP/run/log/ruff-argv")"
FILES_GIVEN="$(awk 'seen { print } $0 == "--" { seen = 1 }' <<<"$ARGS" | LC_ALL=C sort | tr '\n' '|')"
eq "$FILES_GIVEN" "-dash.py|line.py|src/100%,a:b.py|src/broken.py|src/clean.py|src/hits.py|src/new|" "files given to ruff"
for flag in --isolated --exit-zero --no-cache; do
  grep -Fxq -- "$flag" <<<"$ARGS" || fail "ruff not run with $flag"
  ok
done
grep -Fxq -- "$SELECT" <<<"$(awk 'prev == "--select" { print } { prev = $0 }' <<<"$ARGS")" || fail "ruff not run with --select RUFF_SELECT"
ok
grep -Fxq -- 'json' <<<"$(awk 'prev == "--output-format" { print } { prev = $0 }' <<<"$ARGS")" || fail "ruff not run with --output-format json"
ok
# The pinned settings, read from ruff's argv. Without check-typed-exception,
# S110 and S112 do not fire on a typed `except X: pass`, and Claude has been
# told to leave those ids alone, so neither would report it.
eq "$(awk 'prev == "--config" { print } { prev = $0 }' <<<"$ARGS" | LC_ALL=C sort | tr '\n' '|')" \
  "lint.flake8-bandit.check-typed-exception = true|lint.mccabe.max-complexity = 10|lint.pylint.max-args = 4|" \
  "ruff --config values"

has "$S" "${W}-dash.py,line=1,title=ruff T201::\`print\` found" "leading-dash file"
has "$S" "${W}src/100%25%2Ca%3Ab.py,line=1,title=ruff T201::\`print\` found" "% , : escaped in path"
has "$S" "${W}src/new%0Aline.py,line=1,title=ruff T201::\`print\` found" "newline escaped in path"
has "$S" "${W}src/hits.py,line=9,title=ruff PLR0913::Too many arguments in function definition (5 > 4)" "PLR0913"
has "$S" "${W}src/hits.py,line=14,title=ruff PLR2004::Magic value used in comparison, consider replacing \`42\` with a constant variable" "PLR2004"
has "$S" "${W}src/hits.py,line=15,title=ruff T201::\`print\` found" "T201"
has "$S" "${W}src/hits.py,line=16,title=ruff T203::\`pprint\` found" "T203"
has "$S" "${W}src/hits.py,line=19,title=ruff S110::\`try\`-\`except\`-\`pass\` detected, consider logging the exception" "S110"
has "$S" "${W}src/hits.py,line=24,title=ruff S112::\`try\`-\`except\`-\`continue\` detected, consider logging the exception" "S112"
has "$S" "${W}src/hits.py,line=26,title=ruff ERA001::Found commented-out code" "ERA001"
has "$S" "${W}src/hits.py,line=27,title=ruff TD003::Missing issue link for this TODO" "TD003 TODO"
has "$S" "${W}src/hits.py,line=29,title=ruff TD003::Missing issue link for this TODO" "TD003 FIXME"
has "$S" "${W}src/hits.py,line=58,title=ruff TD003::Missing issue link for this TODO" "TD003 XXX"
has "$S" "${W}src/hits.py,line=34,title=ruff C901::\`branchy\` is too complex (11 > 10)" "C901"
hasnt "$S" "src/hits.py,line=30," "noqa line"
hasnt "$S" "old.py" "unchanged file with hits"
hasnt "$S" "clean.py" "changed file without hits"
hasnt "$S" "broken.py" "parse error"
hasnt "$S" "invalid-syntax" "parse error code"
hasnt "$S" "gone.py" "deleted file"
hasnt "$S" "link.py" "symlink"
hasnt "$S" "skip.js" "non-.py file"
eq "$(grep -c '^::warning ' "$S")" 23 "warning count"
hasnt "$S" "::notice::" "no cap notice under the limit"
eq "$(grep -vc '^::' "$S" || true)" 0 "every stdout line is a workflow command"
eq "$(cut -d= -f1 "$O" | LC_ALL=C sort | tr '\n' ' ')" "hit_count hits " "output keys"
has "$O" "hit_count=23" "hit_count"
has "$O" "hits=true" "hits"
grep -Fq '| `src/hits.py` | 34 | C901 | '"'"'branchy'"'"' is too complex (11 > 10) |' "$TMP/run/summary" || { cat "$TMP/run/summary" >&2; fail "summary row"; }
ok
grep -Fq '| `src/new line.py` | 1 |' "$TMP/run/summary" || fail "summary does not flatten a newline in a path"
ok
grep -Fq '**Hits:** 23' "$TMP/run/summary" || fail "summary hit count"
ok

# Default cap: 10 annotations, the rest named in a notice; the summary keeps all.
run "$R" 0 ANNOTATION_LIMIT=10
eq "$(grep -c '^::warning ' "$S")" 10 "annotation cap"
has "$S" "::notice::Ruff advisory lint: 13 further hit(s) appear in the job summary only." "cap notice"
eq "$(grep -c '^| `' "$TMP/run/summary")" 23 "summary lists every hit"

# A hostile message, derived from a real record: escaped, one line, and a
# pipe cannot add a column to the summary table.
jq '.output |= map(if .code == "C901" then .message = "evil%\r\n::error::x | col" else . end)' "$FIXTURE" > "$TMP/hostile.json"
run "$R" 0 STUB_RUFF_FIXTURE="$TMP/hostile.json"
has "$S" "${W}src/hits.py,line=34,title=ruff C901::evil%25%0D%0A::error::x | col" "hostile message escaped"
eq "$(grep -vc '^::' "$S" || true)" 0 "hostile message stays one command"
hasnt "$TMP/run/summary" $'evil%\r' "summary flattens CR"
has "$TMP/run/summary" '| `src/hits.py` | 34 | C901 | evil%  ::error::x \| col |' "summary escapes a pipe in a cell"

# A record with a non-numeric line is not anchored to a line.
jq '.output |= map(if .code == "C901" then .location.row = "34,col=1" else . end)' "$FIXTURE" > "$TMP/shape.json"
run "$R" 0 STUB_RUFF_FIXTURE="$TMP/shape.json"
has "$S" "${W}src/hits.py,title=ruff C901::\`branchy\` is too complex (11 > 10)" "non-numeric line dropped"

# A record for a path outside the checkout, which the step never gave ruff,
# is not reported. The control appends the same record inside the checkout
# and shows that an appended record does reach the annotations.
jq '[.output[] | select(.code == "C901") | .filename = "/etc/passwd"]' "$FIXTURE" > "$TMP/outside.json"
jq '[.output[] | select(.code == "C901") | .filename = "@ROOT@/src/extra.py"]' "$FIXTURE" > "$TMP/inside.json"
[ "$(jq length "$TMP/outside.json")" = 1 ] || fail "outside.json does not hold one record"
ok
run "$R" 0 STUB_RUFF_EXTRA="$TMP/inside.json"
has "$S" "${W}src/extra.py,line=34,title=ruff C901::\`branchy\` is too complex (11 > 10)" "control: an appended record inside the checkout is reported"
has "$O" "hit_count=24" "control hit_count"
run "$R" 0 STUB_RUFF_EXTRA="$TMP/outside.json"
hasnt "$S" "passwd" "path outside the checkout annotated"
hasnt "$TMP/run/summary" "passwd" "path outside the checkout in the summary"
has "$O" "hit_count=23" "hit_count without the outside path"

# A checksum mismatch fails and runs nothing.
run "$R" 1 RUFF_SHA256="$(printf '0%.0s' {1..64})"
has "$S" "::error::Ruff advisory lint: the ruff $VERSION download does not match RUFF_SHA256; refusing to run it." "checksum error"
[ ! -e "$TMP/run/log/ruff-ran" ] || fail "ruff ran after a checksum mismatch"
ok

# A failed download warns, stays green, and reports zero.
run "$R" 0 STUB_CURL_FAIL=1
grep -q "^::warning::Ruff advisory lint: could not download ruff $VERSION; the 6 changed .py file(s) were not linted" "$S" || { cat "$S" >&2; fail "download warning"; }
ok
has "$O" "hit_count=0" "download failure hit_count"

# A ruff crash: green, a warning, stderr fenced so its workflow command is inert.
run "$R" 0 STUB_RUFF_MODE=crash
grep -q '^::warning::Ruff advisory lint: ruff exited 123 ' "$S" || { cat "$S" >&2; fail "crash warning"; }
ok
TOKEN="$(sed -nE 's/^::stop-commands::(.+)$/\1/p' "$S")"
[ -n "$TOKEN" ] || fail "stderr not fenced by stop-commands"
ok
eq "$(awk -v t="::stop-commands::$TOKEN" -v e="::$TOKEN::" '$0 == t { on = 1; next } $0 == e { on = 0 } on' "$S")" '::error::injected from ruff stderr' "stderr inside the fence"
has "$O" "hit_count=0" "crash hit_count"

run "$R" 0 STUB_RUFF_MODE=garbage
grep -q '^::warning::Ruff advisory lint: ruff exited 0 or wrote output that is not JSON arrays' "$S" || { cat "$S" >&2; fail "garbage warning"; }
ok
has "$O" "hits=false" "garbage hits"

# A non-zero exit with valid JSON on stdout is still a ruff failure: under
# --exit-zero a hit exits 0, so its output is not reported.
run "$R" 0 STUB_RUFF_MODE=jsonfail
jq -se 'length == 1 and (.[0] | type == "array" and length > 0)' "$TMP/run/ruff-raw.json" > /dev/null || fail "jsonfail: the stub did not write valid JSON"
ok
grep -q '^::warning::Ruff advisory lint: ruff exited 123 ' "$S" || { cat "$S" >&2; fail "jsonfail warning"; }
ok
hasnt "$S" "$W" "jsonfail: no hit annotated"
has "$O" "hit_count=0" "jsonfail hit_count"

# workflow_dispatch diffs HEAD~1: the same files, the same hits.
run "$R" 0 EVENT_NAME=workflow_dispatch BASE_REF=
has "$O" "hit_count=23" "workflow_dispatch hit_count"

# No changed .py file: nothing downloaded, zero counts.
git -C "$R" update-ref refs/remotes/origin/main HEAD
run "$R" 0
[ ! -e "$TMP/run/log/curl-urls" ] || fail "ruff downloaded with no changed .py file"
ok
eq "$(grep -c '^::' "$S" || true)" 0 "no annotation without .py files"
has "$O" "hit_count=0" "no files hit_count"
has "$O" "hits=false" "no files hits"

# An unreadable range is an error, not a clean result.
git -C "$R" update-ref -d refs/remotes/origin/main
run "$R" 1
has "$S" "::error::Ruff advisory lint: could not list the changed files in origin/main...HEAD" "unreadable range"

# workflow_dispatch on a one-commit repository: a notice, zero, green.
R1="$TMP/one"
mkdir -p "$R1"
git -C "$R1" init -q -b main
git -C "$R1" config user.email t@example.invalid
git -C "$R1" config user.name t
layout_head "$R1"
git -C "$R1" add -A
git -C "$R1" commit -qm only
run "$R1" 0 EVENT_NAME=workflow_dispatch BASE_REF=
has "$S" "::notice::Ruff advisory lint: HEAD has no parent commit; nothing to scan." "no-parent notice"
has "$O" "hit_count=0" "no-parent hit_count"
[ ! -e "$TMP/run/log/curl-urls" ] || fail "ruff downloaded with no parent commit"
ok

echo "PASS: ruff-advisory ($N assertion(s))"

#!/usr/bin/env bash
# Regenerates ruff-output.json, the recorded ruff output run.sh replays.
#
#   bash .github/tests/ruff-advisory/gen.sh <ruff-x86_64-unknown-linux-gnu.tar.gz>
#
# The tarball is the real release asset of the RUFF_VERSION the workflow
# pins. This script runs the workflow's shipped `ruff` step (extracted with
# yq) on the fixture tree, with every file changed so old.py is recorded
# too, serving the tarball through a stub curl and checking it against the
# workflow's own RUFF_SHA256. It keeps ruff's raw JSON and replaces only the
# absolute checkout path with @ROOT@, so the stub can replay it from any
# directory. Not run by the test suite; run it after a ruff bump.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
HERE=.github/tests/ruff-advisory
WF=.github/workflows/reusable-quality-code-smell.yml
TARBALL="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
# shellcheck source=layout.sh
. "$HERE/layout.sh"

STEP='.jobs.analyze.steps[] | select(.id == "ruff")'
VERSION="$(yq -r "$STEP | .env.RUFF_VERSION" "$WF")"
SHA="$(yq -r "$STEP | .env.RUFF_SHA256" "$WF")"
SELECT="$(yq -r "$STEP | .env.RUFF_SELECT" "$WF")"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
yq -r "$STEP | .run" "$WF" > "$TMP/step.sh"
mkdir -p "$TMP/stubs" "$TMP/rt"
cat > "$TMP/stubs/curl" <<'SH'
#!/usr/bin/env bash
out=''
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac; done
cp "$GEN_TARBALL" "$out"
SH
chmod +x "$TMP/stubs/curl"

R="$TMP/repo"
mkdir -p "$R"
git -C "$R" init -q -b main
git -C "$R" config user.email t@example.invalid
git -C "$R" config user.name t
printf 'x\n' > "$R/README.md"
git -C "$R" add -A
git -C "$R" commit -qm base
git -C "$R" update-ref refs/remotes/origin/main HEAD
layout_base "$R"
layout_head "$R"
git -C "$R" add -A
git -C "$R" commit -qm head

( cd "$R" && PATH="$TMP/stubs:$PATH" GEN_TARBALL="$TARBALL" \
    EVENT_NAME=pull_request BASE_REF=main FILE_PATTERNS='**/*.py' GIT_GLOB_PATHSPECS=1 \
    RUFF_VERSION="$VERSION" RUFF_SHA256="$SHA" RUFF_SELECT="$SELECT" \
    RUNNER_TEMP="$TMP/rt" GITHUB_OUTPUT="$TMP/rt/out" GITHUB_STEP_SUMMARY="$TMP/rt/summary" \
    bash "$TMP/step.sh" > /dev/null )
"$TMP/rt/ruff-bin/ruff" --version | grep -Fx "ruff $VERSION" > /dev/null
ROOT="$(cd "$R" && pwd -P)/"
jq -s --arg root "$ROOT" --arg version "$VERSION" \
  '{ruff_version: $version,
    output: (add | map(if (.filename | startswith($root)) then .filename = "@ROOT@/" + (.filename | ltrimstr($root)) else error("path outside the fixture: \(.filename)") end))}' \
  "$TMP/rt/ruff-raw.json" > "$HERE/ruff-output.json"
echo "wrote $HERE/ruff-output.json from ruff $VERSION ($(jq '.output | length' "$HERE/ruff-output.json") record(s))"

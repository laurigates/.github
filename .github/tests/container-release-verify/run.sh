#!/usr/bin/env bash
# The single-quoted ${{ }} strings below are literal workflow expressions.
# shellcheck disable=SC2016
#
# reusable-container-release.yml's `verify` step checks that every published
# tag carries the scanned image, and `cosign-sign` signs what was published.
# On the promote path the candidate can be a single image manifest, and
# `docker buildx imagetools create` then publishes it inside a NEW index with
# its own digest (issue #180). This test runs the shipped steps against:
#
#   - tags that resolve to the candidate digest itself (rebuild path);
#   - tags that resolve to an OCI index, or a Docker manifest list, whose only
#     entry is the candidate (promote path): pass, and the index is signed too;
#   - an index holding the candidate plus another entry, an index holding a
#     different manifest, a plain manifest with another digest, a tag that
#     resolves to nothing, tags that resolve to different digests, and an
#     empty tag list: each fails with an ::error:: line.
#
# It EXTRACTS the shipped `run:` bodies with yq and executes them under
# `bash -e {0}` (the shell GitHub uses for a step with no `shell:`), with stub
# `docker` and `cosign` first on PATH. It never holds a retyped copy of a step.
#
# WORKFLOW overrides the file under test (e.g. a mutated copy, to show a case
# fails when the behaviour it pins is broken).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

NAME=container-release-verify
WORKFLOW=${WORKFLOW:-.github/workflows/reusable-container-release.yml}
SENTINEL=STUB-DOCKER-180c4e

command -v yq >/dev/null || { echo "FAIL: yq is required" >&2; exit 1; }
command -v jq >/dev/null || { echo "FAIL: jq is required" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ASSERTIONS=0
FAILURES=0

fail() { echo "FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }
ok() { ASSERTIONS=$((ASSERTIONS + 1)); }

step_field() { # step-id yq-path
  yq -r ".jobs.release.steps[] | select(.id == \"$1\") | $2" "$WORKFLOW"
}

step_field verify .run > "$WORK/verify.sh"
step_field cosign-sign .run > "$WORK/sign.sh"
for f in verify sign; do
  [ -s "$WORK/$f.sh" ] || { echo "FAIL: could not extract the $f step from $WORKFLOW" >&2; exit 1; }
done

# ---- wiring ----------------------------------------------------------------
check_env() { # step-id key expected
  local got
  got=$(step_field "$1" ".env.$2")
  if [ "$got" = "$3" ]; then ok; else fail "step $1 env $2 is '$got', expected '$3'"; fi
}
check_env verify TAGS '${{ steps.meta.outputs.tags }}'
check_env verify EXPECTED '${{ steps.candidate.outputs.digest }}'
check_env cosign-sign TARGET '${{ steps.candidate.outputs.ref }}'
check_env cosign-sign PUBLISHED '${{ steps.verify.outputs.digest }}'

# ---- stubs -----------------------------------------------------------------
mkdir -p "$WORK/bin"
cat > "$WORK/bin/docker" <<EOF
#!/usr/bin/env bash
# $SENTINEL
# docker buildx imagetools inspect [--raw] <ref>
# \$FIX/tags/<ref with / replaced by _> holds the digest a tag resolves to;
# \$FIX/raw/<digest> holds the raw manifest stored under that digest.
set -euo pipefail
[ "\$1 \$2 \$3" = "buildx imagetools inspect" ] || { echo "stub docker: unexpected \$*" >&2; exit 2; }
shift 3
RAW=false
if [ "\$1" = "--raw" ]; then RAW=true; shift; fi
REF=\$1
case "\$REF" in
  *@sha256:*) DIGEST=\${REF##*@} ;;
  *) KEY=\${REF//\//_}; [ -f "\$FIX/tags/\$KEY" ] || { echo "stub docker: no such tag \$REF" >&2; exit 1; }
     DIGEST=\$(cat "\$FIX/tags/\$KEY") ;;
esac
[ -f "\$FIX/raw/\$DIGEST" ] || { echo "stub docker: no manifest \$DIGEST" >&2; exit 1; }
if \$RAW; then cat "\$FIX/raw/\$DIGEST"; else
  printf 'Name:      %s\nMediaType: %s\nDigest:    %s\n' "\$REF" "\$(jq -r .mediaType "\$FIX/raw/\$DIGEST")" "\$DIGEST"
fi
EOF
cat > "$WORK/bin/cosign" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$COSIGN_LOG"
EOF
chmod +x "$WORK/bin/docker" "$WORK/bin/cosign"
grep -q "$SENTINEL" "$(PATH="$WORK/bin:$PATH" command -v docker)" || { echo "FAIL: stub docker is not first on PATH" >&2; exit 1; }

# ---- fixtures --------------------------------------------------------------
IMAGE=ghcr.io/laurigates/demo
CAND=sha256:$(printf 'c%.0s' {1..64})
OTHER=sha256:$(printf 'a%.0s' {1..64})
IDX_OK=sha256:$(printf '1%.0s' {1..64})
IDX_OK2=sha256:$(printf '2%.0s' {1..64})
IDX_LIST=sha256:$(printf '3%.0s' {1..64})
IDX_TWO=sha256:$(printf '4%.0s' {1..64})
IDX_WRONG=sha256:$(printf '5%.0s' {1..64})

new_fix() {
  FIX="$WORK/fix-$1"
  mkdir -p "$FIX/tags" "$FIX/raw"
  printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json"}' > "$FIX/raw/$CAND"
  printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json"}' > "$FIX/raw/$OTHER"
  index application/vnd.oci.image.index.v1+json "$IDX_OK" "$CAND"
  index application/vnd.oci.image.index.v1+json "$IDX_OK2" "$CAND"
  index application/vnd.docker.distribution.manifest.list.v2+json "$IDX_LIST" "$CAND"
  index application/vnd.oci.image.index.v1+json "$IDX_TWO" "$CAND" "$OTHER"
  index application/vnd.oci.image.index.v1+json "$IDX_WRONG" "$OTHER"
}
index() { # media-type digest entry...
  local mt=$1 d=$2; shift 2
  printf '%s\n' "$@" | jq -R . | jq -s --arg mt "$mt" \
    '{schemaVersion: 2, mediaType: $mt, manifests: map({mediaType: "application/vnd.oci.image.manifest.v1+json", digest: ., platform: {architecture: "amd64", os: "linux"}})}' \
    > "$FIX/raw/$d"
}
tag() { printf '%s' "$2" > "$FIX/tags/${1//\//_}"; } # ref digest

TAGS_ALL="$IMAGE:1.0.0
$IMAGE:1.0
$IMAGE:1
$IMAGE:latest"

# run_case name expect(pass|fail) expected-output-digest expected-sign-count tag-list
run_case() {
  local name=$1 expect=$2 want_digest=$3 want_signs=$4 tags=$5
  local out="$WORK/$name.out" ghout="$WORK/$name.ghout" log="$WORK/$name.cosign"
  : > "$ghout"; : > "$log"
  local rc=0
  env -i PATH="$WORK/bin:/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin" FIX="$FIX" \
    TAGS="$tags" EXPECTED="$CAND" GITHUB_OUTPUT="$ghout" \
    bash -e "$WORK/verify.sh" > "$out" 2>&1 || rc=$?
  if [ "$expect" = pass ]; then
    if [ "$rc" -eq 0 ]; then ok; else fail "$name: verify exited $rc, expected success"; sed 's/^/    /' "$out" >&2; return; fi
    local got
    got=$(sed -n 's/^digest=//p' "$ghout")
    if [ "$got" = "$want_digest" ]; then ok; else fail "$name: digest output '$got', expected '$want_digest'"; fi
    env -i PATH="$WORK/bin:/usr/bin:/bin" COSIGN_LOG="$log" COSIGN_YES=true \
      TARGET="$IMAGE@$CAND" PUBLISHED="$got" GITHUB_OUTPUT="$ghout" \
      bash -e "$WORK/sign.sh" >> "$out" 2>&1 || { fail "$name: sign step failed"; return; }
    local n
    n=$(wc -l < "$log" | tr -d ' ')
    if [ "$n" = "$want_signs" ]; then ok; else fail "$name: cosign ran $n time(s), expected $want_signs"; fi
    if grep -qx "sign $IMAGE@$CAND" "$log"; then ok; else fail "$name: candidate digest was not signed"; fi
    if [ "$want_digest" != "$CAND" ]; then
      if grep -qx "sign $IMAGE@$want_digest" "$log"; then ok; else fail "$name: published index $want_digest was not signed"; fi
    fi
  else
    if [ "$rc" -ne 0 ]; then ok; else fail "$name: verify succeeded, expected failure"; fi
    # A tag docker cannot resolve fails the step through docker's own non-zero
    # exit under `set -o pipefail`, before the step can print anything.
    if [ "$name" != unresolved ]; then
      if grep -q '^::error::' "$out"; then ok; else fail "$name: no ::error:: line"; sed 's/^/    /' "$out" >&2; fi
    fi
    if grep -q '^digest=' "$ghout"; then fail "$name: wrote a digest output on failure"; else ok; fi
  fi
}

new_fix rebuild
for t in $TAGS_ALL; do tag "$t" "$CAND"; done
run_case rebuild pass "$CAND" 1 "$TAGS_ALL"

new_fix promote-oci-index
for t in $TAGS_ALL; do tag "$t" "$IDX_OK"; done
run_case promote-oci-index pass "$IDX_OK" 2 "$TAGS_ALL"

new_fix promote-docker-list
for t in $TAGS_ALL; do tag "$t" "$IDX_LIST"; done
run_case promote-docker-list pass "$IDX_LIST" 2 "$TAGS_ALL"

new_fix index-extra-entry
for t in $TAGS_ALL; do tag "$t" "$IDX_OK"; done
tag "$IMAGE:latest" "$IDX_TWO"
run_case index-extra-entry fail "" 0 "$TAGS_ALL"

new_fix index-wrong-entry
for t in $TAGS_ALL; do tag "$t" "$IDX_WRONG"; done
run_case index-wrong-entry fail "" 0 "$TAGS_ALL"

new_fix other-manifest
for t in $TAGS_ALL; do tag "$t" "$OTHER"; done
run_case other-manifest fail "" 0 "$TAGS_ALL"

new_fix unresolved
tag "$IMAGE:1.0.0" "$IDX_OK"
run_case unresolved fail "" 0 "$TAGS_ALL"

new_fix split-digests
for t in $TAGS_ALL; do tag "$t" "$IDX_OK"; done
tag "$IMAGE:1" "$IDX_OK2"
run_case split-digests fail "" 0 "$TAGS_ALL"

new_fix no-tags
run_case no-tags fail "" 0 ""

if [ "$FAILURES" -gt 0 ]; then
  echo "FAIL: $NAME ($FAILURES failure(s), $ASSERTIONS assertion(s) passed)" >&2
  exit 1
fi
echo "PASS: $NAME ($ASSERTIONS assertion(s))"

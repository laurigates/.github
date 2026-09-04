#!/usr/bin/env bash
# Assert every Claude analysis workflow carries the same publish block.
#
# The block is duplicated on purpose. A composite action cannot be pinned to
# the ref a consumer pinned the reusable workflow to, because `uses:` does not
# accept expressions -- so `laurigates/.github/.github/actions/...@main` would
# execute at floating main even for a consumer who pinned by SHA, and one bad
# push would break the renderer in eight workflows portfolio-wide with no way
# to stage it. A script under .github/scripts/ is not an option either: these
# jobs run actions/checkout with no `repository:`, so the workspace is the
# CALLER's, not this repo's. Colocating the renderer with the schema it
# consumes is also what keeps a field rename in one half visible from the
# other.
#
# Fails on drift AND on absence: a workflow that runs the analysis action but
# carries no publish block is the issue-#47 bug returning.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

BEGIN='      # ---- BEGIN shared publish block'
END='      # ---- END shared publish block ----'
expected="${1:-8}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
found=0
missing=()
status=0

for f in .github/workflows/reusable-*.yml; do
  grep -q -- '--json-schema' "$f" || continue
  if ! grep -qF "$BEGIN" "$f"; then
    missing+=("$f")
    continue
  fi
  found=$((found + 1))
  sed -n "/^${BEGIN}/,/^${END}\$/p" "$f" \
    | sed -E "s/^( +)(TITLE|BLOCKING_SEVERITIES|COUNT_KEYS): .*\$/\1\2: <masked>/" \
    | sed 's/[[:space:]]*$//' > "$work/$(basename "$f").block"
done

if [ ${#missing[@]} -gt 0 ]; then
  printf 'MISSING publish block:\n'
  printf '  %s\n' "${missing[@]}"
  status=1
fi
if [ "$found" -ne "$expected" ]; then
  printf 'FOUND %d publish block(s), expected %d. A shrinking count is the\n' "$found" "$expected"
  printf 'failure this check exists to catch; if deliberate, pass the new count as $1.\n'
  status=1
fi

ref=""
for b in "$work"/*.block; do
  if [ -z "$ref" ]; then
    ref="$b"
    continue
  fi
  if ! diff -u "$ref" "$b" > "$work/d.txt"; then
    printf 'DRIFT: %s differs from %s\n' "$(basename "$b" .block)" "$(basename "$ref" .block)"
    cat "$work/d.txt"
    status=1
  fi
done

[ "$status" -eq 0 ] && printf 'publish-drift: %d block(s), all identical.\n' "$found"
exit "$status"

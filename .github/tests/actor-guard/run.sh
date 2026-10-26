#!/usr/bin/env bash
# Regression test: an analysis workflow triggered by a bot that allowed-bots
# does not list must skip the analysis green and say why, not run
# anthropics/claude-code-action into its "Workflow initiated by non-human
# actor" refusal, which failed the job red without Claude running (every
# Renovate PR in laurigates/comfyui-nodes, e.g. run 40074849105).
#
# Scans every reusable-*.yml carrying --json-schema. For each it checks the
# wiring with yq, then EXTRACTS the shipped `Check actor is allowed` body and
# runs it against actors and allowed-bots values whose outcome under the
# action's own rule is known: a login ending in [bot] is a bot, names compare
# lowercase with surrounding spaces and the [bot] suffix dropped, and '*'
# admits every bot (claude-code-action src/github/validation/actor.ts).
#
# Usage: bash .github/tests/actor-guard/run.sh
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

NAME=actor-guard
command -v yq >/dev/null || { echo "FATAL: yq (mikefarah) is required" >&2; exit 1; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0
checks=0
fail() { printf '  FAIL [%s] %s\n' "$CASE" "$1"; failures=$((failures + 1)); }
ok()   { checks=$((checks + 1)); }

GUARD="steps.actor.outputs.allowed == 'true'"
# conjunct <if-expression>: GUARD is a top-level && operand, with no || and no
# ! other than in != (the same shape event-guard requires of its guard).
conjunct() {
  local expr="$1"
  expr="${expr#"\${{"}"; expr="${expr%"}}"}"
  case "$expr" in *"||"*) return 1 ;; esac
  if printf '%s' "$expr" | grep -qE '![^=]|!$'; then return 1; fi
  printf '%s' "$expr" | awk -v g="$GUARD" '
    BEGIN { RS = "&&"; found = 0 }
    { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if ($0 == g) found = 1 }
    END { exit !found }'
}
CASE=self-test
for bad in "x || $GUARD" "!($GUARD)" "steps.actor.outputs.allowed != 'false'" "${GUARD}x"; do
  ok; if conjunct "$bad"; then fail "conjunct accepted '$bad'"; fi
done
for good in "$GUARD" "a == 'b' && $GUARD"; do
  ok; conjunct "$good" || fail "conjunct rejected '$good'"
done

workflows=()
for f in .github/workflows/reusable-*.yml .github/workflows/reusable-*.yaml; do
  [ -f "$f" ] || continue
  grep -q -- '--json-schema' "$f" || continue
  workflows+=("$f")
done
if [ "${#workflows[@]}" -eq 0 ]; then
  echo "FATAL: no reusable workflow carries --json-schema; nothing to check" >&2
  exit 1
fi

# run_actor <actor> <allowed-bots>: run the extracted body; sets OUT.
run_actor() {
  CASE="$WF_SHORT/actor=$1/allowed=$2"
  rm -rf "$work/run"
  mkdir -p "$work/run"
  OUT="$work/run/output"
  : > "$OUT"
  set +e
  ACTOR="$1" ALLOWED_BOTS="$2" GITHUB_OUTPUT="$OUT" bash "$work/actor.sh" > "$work/run/out.txt" 2> "$work/run/err.txt"
  RC=$?
  set -e
}
expect() { # <allowed true|false> [<refused value>]
  ok; [ "$RC" = 0 ] || fail "exit $RC: $(head -c 200 "$work/run/err.txt")"
  ok; grep -qx "allowed=$1" "$OUT" || fail "expected allowed=$1, got: $(tr '\n' ' ' < "$OUT")"
  if [ "$1" = false ]; then
    ok; grep -qxF "refused=$2" "$OUT" || fail "expected refused=$2, got: $(tr '\n' ' ' < "$OUT")"
  else
    ok; if grep -q '^refused=' "$OUT"; then fail "allowed actor also wrote refused="; fi
  fi
  ok; if grep -q '^::' "$work/run/out.txt"; then fail "the step printed a workflow command; the shared report owns the notice"; fi
}

ref_body=""
for WF in "${workflows[@]}"; do
  WF_SHORT="$(basename "$WF" .yml)"
  CASE="$WF_SHORT/wiring"
  steps='[.jobs.*.steps[]]'
  idx() { ID="$1" yq "$steps | to_entries | map(select(.value.id == strenv(ID))) | .[0].key // -1" "$WF"; }
  i_event="$(idx event)"; i_actor="$(idx actor)"; i_analyze="$(idx analyze)"
  ok
  if [ "$i_actor" = -1 ]; then
    fail "no step with id 'actor'"
    continue
  fi
  ok; [ "$i_event" -lt "$i_actor" ] && [ "$i_actor" -lt "$i_analyze" ] \
    || fail "step order must be event < actor < analyze (got $i_event $i_actor $i_analyze)"
  # One equality per call: yq's `and` returned false here with both sides true.
  ok
  # shellcheck disable=SC2016 # literal ${{ }} expressions
  yq -e '[.jobs.*.steps[] | select(.id == "actor")] | .[0].env.ACTOR == "${{ github.actor }}"' "$WF" >/dev/null 2>&1 \
    || fail "the actor step must bind ACTOR to github.actor via env:"
  ok
  # shellcheck disable=SC2016
  yq -e '[.jobs.*.steps[] | select(.id == "actor")] | .[0].env.ALLOWED_BOTS == "${{ inputs.allowed-bots }}"' "$WF" >/dev/null 2>&1 \
    || fail "the actor step must bind ALLOWED_BOTS to inputs.allowed-bots via env:"
  # The analysis step's allowed_bots is the same input the gate reads.
  ok
  # shellcheck disable=SC2016
  yq -e '[.jobs.*.steps[] | select(.id == "analyze")] | .[0].with.allowed_bots == "${{ inputs.allowed-bots }}"' "$WF" >/dev/null 2>&1 \
    || fail "analyze passes allowed_bots other than inputs.allowed-bots, so the gate and the action disagree"
  # Every step after the gate up to and including analyze requires it.
  while IFS=$'\t' read -r i sname sif; do
    CASE="$WF_SHORT/gated[$i]"
    ok; conjunct "$sif" || fail "step '$sname' does not require \"$GUARD\" as a top-level && operand of its if: ('$sif')"
  done < <(yq -r "$steps | to_entries | .[] | select(.key > $i_actor and .key <= $i_analyze) | (.key | tostring) + \"\\t\" + .value.name + \"\\t\" + (.value.if // \"\")" "$WF")
  CASE="$WF_SHORT/wiring"
  ok
  # shellcheck disable=SC2016
  yq -e '[.jobs.*.steps[] | select(.name == "Report that nothing was scanned")] | .[0].env.REFUSED_ACTOR == "${{ steps.actor.outputs.refused }}"' "$WF" >/dev/null 2>&1 \
    || fail "'Report that nothing was scanned' does not bind REFUSED_ACTOR to steps.actor.outputs.refused"

  yq '[.jobs.*.steps[] | select(.id == "actor")] | .[0].run' "$WF" > "$work/actor.sh"
  ok
  # shellcheck disable=SC2016 # a literal ${{, not a shell expansion
  if grep -qF '${{' "$work/actor.sh"; then fail "the actor step's run body interpolates an expression"; fi
  ok
  if [ -z "$ref_body" ]; then
    ref_body="$work/ref-actor.sh"
    cp "$work/actor.sh" "$ref_body"
  elif ! diff -q "$ref_body" "$work/actor.sh" >/dev/null; then
    fail "actor step body differs from the one in ${workflows[0]}"
  fi

  # Behaviour, against the action's rule.
  run_actor laurigates '';                                   expect true
  run_actor 'laurigates-renovate[bot]' '';                   expect false 'laurigates-renovate[bot]'
  run_actor 'laurigates-renovate[bot]' 'claude[bot],claude'; expect false 'laurigates-renovate[bot]'
  run_actor 'laurigates-renovate[bot]' 'laurigates-renovate'; expect true
  run_actor 'laurigates-renovate[bot]' 'claude, Laurigates-Renovate[bot] '; expect true
  run_actor 'github-actions[bot]' 'claude[bot],claude,github-actions[bot]'; expect true
  run_actor 'Claude[bot]' 'claude[bot]';                     expect true
  run_actor 'renovate[bot]' ' * ';                           expect true
  run_actor 'renovate[bot]' '*,claude';                      expect false 'renovate[bot]'
  run_actor 'renovate[bot]' 'laurigates-renovate[bot]';      expect false 'renovate[bot]'
  # Refused output is filtered to login characters.
  # shellcheck disable=SC2016 # a literal $( in the login, not an expansion
  run_actor 'evil$(id)[bot]' '';                             expect false 'evilid[bot]'
done

if [ "$failures" -ne 0 ]; then
  printf 'FAIL: %s (%d of %d assertion(s) failed across %d workflow(s))\n' "$NAME" "$failures" "$checks" "${#workflows[@]}"
  exit 1
fi
printf 'PASS: %s (%d assertion(s) across %d workflow(s))\n' "$NAME" "$checks" "${#workflows[@]}"

#!/usr/bin/env bash
# Regression test for laurigates/.github#63: an analysis workflow called on an
# event anthropics/claude-code-action rejects (push, merge_group, release, ...)
# must skip the analysis green and say why, not run the action into its own
# `Unsupported event type` throw and fail red in a way that reads like a scan
# finding.
#
# Scans the same workflows as scripts/check-publish-drift.sh (every
# reusable-*.yml carrying --json-schema). For each one it checks the wiring
# with yq and EXTRACTS the shipped `Check trigger is supported` step body and
# runs it per event. No retyped copy. The text of the `Report that nothing
# was scanned` step lives in the shared publish block and is exercised by
# .github/tests/publish-findings/run.sh.
#
# Usage: bash .github/tests/event-guard/run.sh
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

NAME=event-guard
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0
checks=0
fail() { printf '  FAIL [%s] %s\n' "$CASE" "$1"; failures=$((failures + 1)); }
ok()   { checks=$((checks + 1)); }

command -v yq >/dev/null || { echo "FATAL: yq (mikefarah) is required" >&2; exit 1; }

# The events anthropics/claude-code-action v1 accepts: the `case` labels of
# `switch (context.eventName)` in src/github/context.ts (170-251). Anything
# else reaches the `default:` that throws `Unsupported event type`.
ALLOWED=(issues issue_comment pull_request pull_request_target pull_request_review
  pull_request_review_comment workflow_dispatch repository_dispatch schedule workflow_run)
REFUSED=(push merge_group release create delete deployment deployment_status check_run
  check_suite status pull_request_review_thread workflow_call)
GUARD="steps.event.outputs.supported == 'true'"

# guard_conjunct <if-expression>: succeed only when GUARD is a required,
# top-level `&&` operand. A substring match is not enough: `A || GUARD` fails
# OPEN on a refused event (a skipped `changed` leaves count '', and '' != '0'),
# and `!(GUARD)` inverts it. So: no `||`, no `!` other than in `!=`, and one
# `&&`-separated operand equal to GUARD exactly.
guard_conjunct() {
  local expr="$1"
  expr="${expr#"\${{"}"; expr="${expr%"}}"}"
  case "$expr" in *"||"*) return 1 ;; esac
  if printf '%s' "$expr" | grep -qE '![^=]|!$'; then return 1; fi
  printf '%s' "$expr" | awk -v g="$GUARD" '
    BEGIN { RS = "&&"; found = 0 }
    { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if ($0 == g) found = 1 }
    END { exit !found }'
}

# Self-test the checker on the shapes it exists to reject, so a loosened
# check cannot silently pass every workflow.
CASE=self-test
for bad in \
  "steps.changed.outputs.count != '0' || $GUARD" \
  "$GUARD || steps.changed.outputs.count != '0'" \
  "!($GUARD)" \
  "!$GUARD" \
  "steps.event.outputs.supported != 'false'" \
  "x && ($GUARD || y)" \
  "${GUARD}x"; do
  ok
  if guard_conjunct "$bad"; then fail "guard_conjunct accepted '$bad'"; fi
done
for good in "$GUARD" "\${{ $GUARD }}" "a != '0' && b != 'true' && $GUARD" "$GUARD && inputs.x == 'y'"; do
  ok
  guard_conjunct "$good" || fail "guard_conjunct rejected '$good'"
done
ALLOWED_SORTED="$(printf '%s\n' "${ALLOWED[@]}" | sort)"

workflows=()
for f in .github/workflows/reusable-*.yml; do
  grep -q -- '--json-schema' "$f" || continue
  workflows+=("$f")
done
# An empty scan is green by construction and would pin nothing.
if [ "${#workflows[@]}" -eq 0 ]; then
  echo "FATAL: no reusable workflow carries --json-schema; nothing to check" >&2
  exit 1
fi

# run_event <event-name>: run the extracted step with that event.
run_event() {
  CASE="$WF_SHORT/event=${1:-<empty>}"
  rm -rf "$work/run"
  mkdir -p "$work/run"
  set +e
  EVENT_NAME="$1" TITLE='Test Analysis' \
    GITHUB_OUTPUT="$work/run/output" GITHUB_STEP_SUMMARY="$work/run/summary.md" \
    bash "$work/event.sh" > "$work/run/out.txt" 2> "$work/run/err.txt"
  RC=$?
  set -e
  OUT="$work/run/output"
  touch "$OUT"
}
assert_rc()    { ok; [ "$RC" = "$1" ] || fail "expected rc $1, got $RC ($(head -c 300 "$work/run/err.txt"))"; }
assert_lines() { ok; local n; n="$(grep -c -- "$2" "$1" || true)"; [ "$n" = "$3" ] || fail "expected $3 line(s) matching '$2' in $(basename "$1"), got $n"; }

ref_body=""
for WF in "${workflows[@]}"; do
  WF_SHORT="$(basename "$WF" .yml)"
  CASE="$WF_SHORT/wiring"

  # 1. The guard step exists, always runs, and runs before the file list.
  idx_event="$(yq '[.jobs.*.steps[]] | to_entries | map(select(.value.id == "event")) | .[0].key // -1' "$WF")"
  idx_changed="$(yq '[.jobs.*.steps[]] | to_entries | map(select(.value.id == "changed")) | .[0].key // -1' "$WF")"
  idx_analyze="$(yq '[.jobs.*.steps[]] | to_entries | map(select(.value.id == "analyze")) | .[0].key // -1' "$WF")"
  ok
  if [ "$idx_event" = "-1" ]; then
    fail "no step with id 'event': nothing stops claude-code-action from throwing 'Unsupported event type' on push"
  else
    ok
    [ "$idx_event" -lt "$idx_changed" ] || fail "the 'event' step (index $idx_event) must run before 'changed' (index $idx_changed)"
    ok
    [ "$(yq '[.jobs.*.steps[] | select(.id == "event")] | .[0] | has("if")' "$WF")" = "false" ] \
      || fail "the 'event' step carries an if:; it must always run, or its unset output silently decides"
    ok
    # shellcheck disable=SC2016 # a literal ${{ }} expression, not a shell expansion
    yq -e '[.jobs.*.steps[] | select(.id == "event")] | .[0].env.EVENT_NAME == "${{ github.event_name }}"' "$WF" >/dev/null 2>&1 \
      || fail "the 'event' step does not bind EVENT_NAME to github.event_name via env:"
  fi

  # 2. The analysis step is gated on the guard, as a string equality, so an
  #    output that was never set (step skipped, renamed, removed) fails closed.
  analyze_if="$(yq '[.jobs.*.steps[] | select(.id == "analyze")] | .[0].if // ""' "$WF")"
  ok
  guard_conjunct "$analyze_if" \
    || fail "analyze if: '$analyze_if' does not require \"$GUARD\" as a top-level && operand (no ||, no !)"
  ok
  case "$analyze_if" in
    *"supported != 'false'"*) fail "analyze if: compares supported != 'false', which fails OPEN on an unset output" ;;
  esac

  # 3. Every step between the guard and the analysis is gated too, so a
  #    refused event runs nothing that could turn the job red (security-deps'
  #    setup and audit steps, a checkout with full history, the diff).
  if [ "$idx_event" != "-1" ] && [ "$idx_analyze" != "-1" ]; then
    while IFS=$'\t' read -r i sname sif; do
      CASE="$WF_SHORT/pre-analyze[$i]"
      ok
      guard_conjunct "$sif" \
        || fail "step '$sname' runs before analyze without \"$GUARD\" as a top-level && operand of its if: ('$sif')"
    done < <(yq -r "[.jobs.*.steps[]] | to_entries | .[] | select(.key > $idx_event and .key < $idx_analyze) | (.key | tostring) + \"\\t\" + .value.name + \"\\t\" + (.value.if // \"\")" "$WF")
  fi
  CASE="$WF_SHORT/wiring"

  # 4. The nothing-scanned report must be told which event was refused, or it
  #    names the wrong reason ("no changed file matched").
  ok
  # shellcheck disable=SC2016
  yq -e '[.jobs.*.steps[] | select(.name == "Report that nothing was scanned")] | .[0].env.UNSUPPORTED_EVENT == "${{ steps.event.outputs.unsupported }}"' "$WF" >/dev/null 2>&1 \
    || fail "'Report that nothing was scanned' does not bind UNSUPPORTED_EVENT to steps.event.outputs.unsupported"

  # 5. The shipped guard body, extracted rather than retyped.
  awk '
    /^      - name: Check trigger is supported$/ { inv = 1 }
    inv && /^        run: \|$/                  { inrun = 1; next }
    inrun && /^      [-#]/                      { inrun = 0; inv = 0 }
    inrun && /^[[:space:]]*$/                   { blank = blank "\n"; next }
    inrun                                       { printf "%s%s\n", blank, $0; blank = "" }
  ' "$WF" | sed 's/^          //' > "$work/event.sh"
  ok
  if [ ! -s "$work/event.sh" ]; then
    fail "no 'Check trigger is supported' run body found"
    continue
  fi
  ok
  # shellcheck disable=SC2016 # a literal ${{, not a shell expansion
  if grep -qF '${{' "$work/event.sh"; then
    fail "the guard's run body interpolates an expression: $(grep -F '${{' "$work/event.sh" | head -1)"
  fi
  ok
  if [ -z "$ref_body" ]; then
    ref_body="$work/ref-event.sh"
    cp "$work/event.sh" "$ref_body"
  elif ! diff -q "$ref_body" "$work/event.sh" >/dev/null; then
    fail "guard body differs from the one in ${workflows[0]}"
  fi

  # 5b. The allowlist is an exact copy of upstream's switch, not a superset:
  #     the behaviour cases below sample refused events, so an extra label
  #     (deployment, check_run, ...) would otherwise pass unnoticed. Exactly
  #     one case arm may write supported=true, and its labels must equal ALLOWED.
  ok
  n_true="$(grep -c 'supported=true' "$work/event.sh" || true)"
  [ "$n_true" = "1" ] || fail "expected exactly 1 line writing supported=true in the guard body, got $n_true"
  ok
  labels="$(grep -B1 'supported=true' "$work/event.sh" | head -1)"
  if ! printf '%s\n' "$labels" | grep -qE '^[[:space:]]*[a-z_]+([[:space:]]*\|[[:space:]]*[a-z_]+)*\)[[:space:]]*$'; then
    fail "the line before supported=true is not a plain case-label list: '$labels'"
  else
    got_sorted="$(printf '%s' "$labels" | tr -d ')' | tr '|' '\n' | tr -d '[:blank:]' | sed '/^$/d' | sort)"
    [ "$got_sorted" = "$ALLOWED_SORTED" ] \
      || fail "guard allowlist differs from claude-code-action v1 context.ts: $(diff <(printf '%s\n' "$ALLOWED_SORTED") <(printf '%s\n' "$got_sorted") | grep '^[<>]' | tr '\n' ' ')"
  fi

  # 6. Behaviour.
  for ev in "${ALLOWED[@]}"; do
    run_event "$ev"
    assert_rc 0
    assert_lines "$OUT" '^supported=true$' 1
    assert_lines "$OUT" '^unsupported=' 0
    # The step only decides; the shared 'Report that nothing was scanned'
    # step publishes the one notice and summary section a refusal gets.
    assert_lines "$work/run/out.txt" '^::' 0
  done
  for ev in "${REFUSED[@]}"; do
    run_event "$ev"
    assert_rc 0
    assert_lines "$OUT" '^supported=false$' 1
    assert_lines "$OUT" "^unsupported=$ev\$" 1
    assert_lines "$work/run/out.txt" '^::' 0
    assert_lines "$work/run/out.txt" "'$ev'" 1
  done
  # No event name at all must still refuse, and still name something, or the
  # report falls back to the wrong reason.
  run_event ''
  assert_rc 0
  assert_lines "$OUT" '^supported=false$' 1
  assert_lines "$OUT" '^unsupported=unknown$' 1
done

if [ "$failures" -ne 0 ]; then
  printf 'FAIL: %s (%d of %d assertion(s) failed across %d workflow(s))\n' "$NAME" "$failures" "$checks" "${#workflows[@]}"
  exit 1
fi
printf 'PASS: %s (%d assertion(s) across %d workflow(s))\n' "$NAME" "$checks" "${#workflows[@]}"

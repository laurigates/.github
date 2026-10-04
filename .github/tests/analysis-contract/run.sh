#!/usr/bin/env bash
# Regression test for laurigates/.github#65 (upstream
# ForumViriumHelsinki/.github#115 §2): the request half of the fix. The
# publish block (publish-findings) and the verdict step (analysis-verdict)
# only help if findings reach them, and that depends on three things in each
# workflow that neither of those tests reads:
#
#   1. the --json-schema asks for an itemised `findings` array, and declares
#      every count the publish step reads and every severity the gate blocks on
#   2. the prompt no longer tells Claude to "Leave a PR comment" (it has no
#      tool to do so, and the findings went nowhere) and has a Reporting section
#   3. job outputs and gates read the publish step's type-checked outputs,
#      compare them numerically (`> 0`, never `!= '0'`), carry no `always()`,
#      and never read structured_output directly; a `fail-on-*` gate is the
#      union of the itemised `blocking` count and the reported count
#
# Scans EVERY workflow that runs anthropics/claude-code-action with
# --json-schema, and reads the shipped YAML with yq rather than a retyped copy.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

NAME=analysis-contract
failures=0
checks=0
fail() { printf '  FAIL [%s] %s\n' "$CASE" "$1"; failures=$((failures + 1)); }
ok()   { checks=$((checks + 1)); }

command -v jq >/dev/null || { echo "FATAL: jq is required" >&2; exit 1; }
command -v yq >/dev/null || { echo "FATAL: yq is required" >&2; exit 1; }

workflows=()
for f in .github/workflows/*.yml workflow-templates/*.yml; do
  [ -f "$f" ] || continue
  grep -q 'anthropics/claude-code-action@' "$f" || continue
  grep -q -- '--json-schema' "$f" || continue
  workflows+=("$f")
done
# An empty scan is green by construction and would pin nothing.
if [ "${#workflows[@]}" -eq 0 ]; then
  echo "FATAL: no workflow runs claude-code-action with --json-schema; the scan found nothing to check" >&2
  exit 1
fi

# in_list <needle> <comma-separated list>
in_list() { case ",$2," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

for WF in "${workflows[@]}"; do
  CASE="$(basename "$WF" .yml)"
  ANALYZE='[.jobs.*.steps[] | select((.uses // "") | test("^anthropics/claude-code-action@")) | select((.with.claude_args // "") | test("--json-schema"))]'

  ok
  n="$(yq "$ANALYZE | length" "$WF")"
  if [ "$n" != "1" ]; then
    fail "expected exactly one claude-code-action step passing --json-schema, found $n"
    continue
  fi

  # ---- 1. The schema ----
  ARGS="$(yq "$ANALYZE | .[0].with.claude_args" "$WF")"
  SCHEMA="$(sed -n "s/.*--json-schema '\\([^']*\\)'.*/\\1/p" <<<"$ARGS")"
  ok
  if [ -z "$SCHEMA" ] || ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$SCHEMA"; then
    fail "could not extract a JSON object from --json-schema '...' in claude_args"
    continue
  fi
  ok; jq -e '.properties.findings.type == "array"' >/dev/null <<<"$SCHEMA" \
    || fail "--json-schema has no 'findings' array property: counts alone reach the publish step, and nothing is itemised"
  ok; jq -e '(.required // []) | index("findings") != null' >/dev/null <<<"$SCHEMA" \
    || fail "--json-schema does not list 'findings' in required"
  for key in file severity description; do
    ok; jq -e --arg k "$key" '(.properties.findings.items.required // []) | index($k) != null' >/dev/null <<<"$SCHEMA" \
      || fail "--json-schema findings items do not require '$key', which the publish step renders"
  done
  ok; jq -e '(.properties.findings.items.properties.severity.enum // []) | length > 0' >/dev/null <<<"$SCHEMA" \
    || fail "--json-schema findings items have no severity enum"

  PUBLISH='[.jobs.*.steps[] | select(.id == "publish")] | .[0]'
  COUNT_KEYS="$(yq "$PUBLISH | .env.COUNT_KEYS // \"\"" "$WF")"
  BLOCKING_SEVERITIES="$(yq "$PUBLISH | .env.BLOCKING_SEVERITIES // \"\"" "$WF")"
  ok; [ -n "$COUNT_KEYS" ] || fail "no publish step with a COUNT_KEYS env value"
  IFS=, read -r -a count_keys <<<"$COUNT_KEYS"
  for key in "${count_keys[@]}"; do
    ok; jq -e --arg k "$key" '.properties[$k].type == "integer" and ((.required // []) | index($k) != null)' >/dev/null <<<"$SCHEMA" \
      || fail "COUNT_KEYS names '$key', but --json-schema does not declare it as a required integer"
  done
  if [ -n "$BLOCKING_SEVERITIES" ]; then
    IFS=, read -r -a blocking <<<"$BLOCKING_SEVERITIES"
    for sev in "${blocking[@]}"; do
      ok; jq -e --arg s "$sev" '(.properties.findings.items.properties.severity.enum // []) | index($s) != null' >/dev/null <<<"$SCHEMA" \
        || fail "BLOCKING_SEVERITIES names '$sev', which is not in the findings severity enum, so it can never block"
    done
  fi

  # ---- 2. The prompt ----
  PROMPT="$(yq "$ANALYZE | .[0].with.prompt // \"\"" "$WF")"
  ok; if grep -qi 'leave a PR comment' <<<"$PROMPT"; then
    fail "prompt still asks Claude to 'Leave a PR comment'; the job grants no comment tool, so those findings are lost"
  fi
  ok; grep -q '^## Reporting$' <<<"$PROMPT" \
    || fail "prompt has no '## Reporting' section telling Claude to report through the structured output"
  ok; grep -q 'findings' <<<"$PROMPT" \
    || fail "prompt never mentions 'findings', so the model is not asked to itemise"

  # ---- 3. Job outputs and gates ----
  # Each query is captured before it is iterated: a failing yq inside
  # `< <(...)` is silent under set -e and would read as "nothing to check".
  JOB_OUTPUTS="$(yq -r '.jobs.*.outputs // {} | to_entries | .[] | .key + "\t" + (.value | tostring)' "$WF")"
  CONDITIONS="$(yq -r '(.jobs.* | select(.if != null) | .if), (.jobs.*.steps[] | select(.if != null) | .if)' "$WF")"
  FAIL_ON_INPUTS="$(yq -r '.on.workflow_call.inputs // {} | keys | .[] | select(test("^fail-on-"))' "$WF")"
  # Control: every one of these workflows gates at least its analysis step.
  ok; [ -n "$CONDITIONS" ] || fail "no step conditions extracted; the condition checks below would be vacuous"

  while IFS=$'\t' read -r out_name out_value; do
    [ -n "$out_name" ] || continue
    ok
    if [[ "$out_value" =~ ^\$\{\{\ steps\.publish\.outputs\.count_([a-z_]+)\ \}\}$ ]]; then
      in_list "${BASH_REMATCH[1]}" "$COUNT_KEYS" \
        || fail "job output '$out_name' reads count_${BASH_REMATCH[1]}, which is not in COUNT_KEYS ($COUNT_KEYS)"
    else
      fail "job output '$out_name' is '$out_value', expected \${{ steps.publish.outputs.count_<key> }}: only the publish step's outputs are type-checked"
    fi
  done <<<"$JOB_OUTPUTS"

  while IFS= read -r cond; do
    [ -n "$cond" ] || continue
    ok
    if grep -q 'always()' <<<"$cond"; then
      fail "condition carries always(), which masks an upstream failure: $cond"
    fi
    ok
    if grep -q 'structured_output' <<<"$cond"; then
      fail "condition reads structured_output directly instead of the publish step's outputs: $cond"
    fi
    ok
    # awk's gsub returns the match count; grep -o exits 1 on none, which
    # pipefail would turn into an abort.
    refs="$(awk '{ n += gsub(/steps\.publish\.outputs\.[A-Za-z0-9_]+/, "") } END { print n + 0 }' <<<"$cond")"
    numeric="$(awk '{ n += gsub(/steps\.publish\.outputs\.[A-Za-z0-9_]+ > 0/, "") } END { print n + 0 }' <<<"$cond")"
    [ "$refs" = "$numeric" ] \
      || fail "condition compares a publish output other than as '> 0' ($numeric of $refs numeric); '!= '\''0'\''' fires on the empty string a skipped step leaves: $cond"
  done <<<"$CONDITIONS"

  while IFS= read -r input; do
    [ -n "$input" ] || continue
    GATE="[.jobs.*.steps[] | select((.if // \"\") | test(\"inputs\\\\.$input\\\\b\"))]"
    ok
    g="$(yq "$GATE | length" "$WF")"
    if [ "$g" != "1" ]; then
      fail "input '$input' gates $g step(s), expected exactly 1"
      continue
    fi
    ok; [ -n "$BLOCKING_SEVERITIES" ] \
      || fail "input '$input' gates the job, but the publish step's BLOCKING_SEVERITIES is empty, so 'blocking' is always 0"
    REPORTED="$(yq "$GATE | .[0].env.REPORTED // \"\"" "$WF")"
    ok
    if [[ "$REPORTED" =~ ^\$\{\{\ steps\.publish\.outputs\.(count_([a-z_]+))\ \}\}$ ]]; then
      in_list "${BASH_REMATCH[2]}" "$COUNT_KEYS" \
        || fail "gate '$input' reports ${BASH_REMATCH[1]}, which is not in COUNT_KEYS ($COUNT_KEYS)"
      want="inputs.$input && (steps.publish.outputs.blocking > 0 || steps.publish.outputs.${BASH_REMATCH[1]} > 0)"
      got="$(yq "$GATE | .[0].if" "$WF")"
      ok; [ "$got" = "$want" ] || fail "gate '$input' is '$got', expected the union '$want'"
    else
      fail "gate '$input' has no REPORTED env reading \${{ steps.publish.outputs.count_<key> }}, so it cannot fire on the reported count"
    fi
  done <<<"$FAIL_ON_INPUTS"
done

if [ "$failures" -ne 0 ]; then
  printf 'FAIL: %s (%d of %d assertion(s) failed across %d workflow(s))\n' "$NAME" "$failures" "$checks" "${#workflows[@]}"
  exit 1
fi
printf 'PASS: %s (%d assertion(s))\n' "$NAME" "$checks"

# laurigates/.github - Community health files & reusable workflows
# Run `just` or `just help` to see available recipes

set positional-arguments

# Must equal ACTIONLINT_VERSION in .github/workflows/lint.yml (tool-pins checks it).
actionlint_version := "1.7.12"

# Show available recipes
default:
    @just --list

####################
# Workflow Sync
####################

# Compare reusable workflows against upstream FVH org
[group: "sync"]
diff-upstream:
    #!/usr/bin/env bash
    set -euo pipefail
    upstream="/Users/lgates/repos/ForumViriumHelsinki/.github/.github/workflows"
    local=".github/workflows"
    changed=0
    echo "=== Comparing reusable workflows against FVH upstream ==="
    echo ""
    for local_file in "$local"/reusable-*.yml; do
        name=$(basename "$local_file")
        upstream_file="$upstream/$name"
        if [[ ! -f "$upstream_file" ]]; then
            printf "  %-50s %s\n" "$name" "personal-only"
            continue
        fi
        if diff -q "$upstream_file" "$local_file" >/dev/null 2>&1; then
            printf "  %-50s %s\n" "$name" "identical"
        else
            printf "  %-50s %s\n" "$name" "DIFFERS"
            changed=$((changed + 1))
        fi
    done
    # Check for upstream-only workflows
    for upstream_file in "$upstream"/reusable-*.yml; do
        name=$(basename "$upstream_file")
        if [[ ! -f "$local/$name" ]]; then
            printf "  %-50s %s\n" "$name" "upstream-only"
        fi
    done
    echo ""
    if [[ $changed -eq 0 ]]; then
        echo "All shared workflows are in sync."
    else
        echo "$changed workflow(s) differ. Run 'just diff-upstream-detail <name>' to see details."
    fi

# Show detailed diff for a specific workflow
[group: "sync"]
diff-upstream-detail name:
    #!/usr/bin/env bash
    set -euo pipefail
    upstream="/Users/lgates/repos/ForumViriumHelsinki/.github/.github/workflows/reusable-{{name}}.yml"
    local=".github/workflows/reusable-{{name}}.yml"
    if [[ ! -f "$upstream" ]]; then
        echo "No upstream workflow: $upstream"
        exit 1
    fi
    if [[ ! -f "$local" ]]; then
        echo "No local workflow: $local"
        exit 1
    fi
    diff --color -u "$upstream" "$local" || true

# List recent upstream workflow changes
[group: "sync"]
upstream-changes days="14":
    #!/usr/bin/env bash
    set -euo pipefail
    upstream="/Users/lgates/repos/ForumViriumHelsinki/.github"
    echo "=== FVH upstream workflow changes (last {{days}} days) ==="
    git -C "$upstream" log \
        --since="{{days}} days ago" \
        --oneline \
        --name-only \
        -- '.github/workflows/reusable-*.yml' \
    | head -50

# Fail if upstream-org identifiers leaked into this repo's sources
[group: "sync"]
leak-check:
    #!/usr/bin/env bash
    set -euo pipefail
    paths=(.github/workflows .github/actions .github/tests scripts)
    [[ -f rulesync.jsonc ]] && paths+=(rulesync.jsonc)
    [[ -d .rulesync ]] && paths+=(.rulesync)
    if rg -in 'fvh|forumvirium' "${paths[@]}"; then
        echo ""
        echo "Upstream identifiers leaked — sanitize before committing (see .claude/skills/sync-upstream-workflows.md)."
        exit 1
    fi
    echo "leak-check: clean"

####################
# Validation
####################

# Validate workflows: YAML syntax + actionlint (shellcheck pass-through off)
[group: "validate"]
lint:
    #!/usr/bin/env bash
    set -euo pipefail
    errors=0
    shopt -s nullglob
    # yq, not `python3 -c "import yaml"`: the CI job runs on ubuntu-slim, which
    # ships yq but no PyYAML, so the Python form passes here and fails there.
    # Composite actions are shipped from this repo too and are consumed by the
    # reusable workflows, so they belong in the same syntax gate. actionlint
    # below only understands workflow files, hence the separate YAML pass.
    for f in .github/workflows/*.yml .github/actions/*/action.yml; do
        if ! yq -e 'tag == "!!map"' "$f" >/dev/null; then
            echo "INVALID: $f"
            errors=$((errors + 1))
        fi
    done
    shopt -u nullglob
    if [[ $errors -eq 0 ]]; then
        echo "All workflow and action files are valid YAML."
    else
        echo "$errors file(s) have YAML errors."
        exit 1
    fi
    if command -v mise >/dev/null 2>&1; then
        al=(mise exec "aqua:rhysd/actionlint@{{ actionlint_version }}" -- actionlint)
    elif command -v actionlint >/dev/null 2>&1; then
        al=(actionlint)
    else
        echo "actionlint not found: install mise or actionlint {{ actionlint_version }}" >&2
        exit 1
    fi
    # -shellcheck= disables shellcheck integration: its style findings on
    # run: blocks are accepted pre-existing noise; actionlint still checks
    # expressions, action inputs, and workflow structure.
    "${al[@]}" -shellcheck= -oneline .github/workflows/*.yml
    echo "actionlint: clean"

# Generate the rules in a scratch repo with the pinned rulesync (lint.yml's step, extracted); never at the root
[group: "validate"]
rules-check:
    #!/usr/bin/env bash
    set -euo pipefail
    step='rulesync generate (scratch copy)'
    body=$(STEP="$step" yq '.jobs.lint.steps[] | select(.name == strenv(STEP)) | .run // ""' .github/workflows/lint.yml)
    [ -n "$body" ] || { echo "no step named '$step' in lint.yml" >&2; exit 1; }
    bash --noprofile --norc -eo pipefail -c "$body"

# Run every test under .github/tests/, or only the named ones
[group: "validate"]
test *names:
    @bash .github/tests/run.sh "$@"

# Fail if the shared publish block has drifted between analysis workflows
[group: "validate"]
publish-drift count="8":
    bash scripts/check-publish-drift.sh "{{count}}"

# Run the publish-block renderer against its fixtures
[group: "validate"]
publish-fixtures workflow=".github/workflows/reusable-security-owasp.yml":
    bash .github/tests/publish-findings/run.sh "{{workflow}}"

# Run every --json-schema analysis workflow's Classify step against fixtures
[group: "validate"]
analysis-verdict:
    bash .github/tests/analysis-verdict/run.sh

# Check the analysis workflows' schema, prompt and gate contract
[group: "validate"]
analysis-contract:
    bash .github/tests/analysis-contract/run.sh

# Check the analysis workflows refuse events claude-code-action rejects (#63)
[group: "validate"]
event-guard-fixtures:
    bash .github/tests/event-guard/run.sh

# Run reusable-auto-fix.yml's issue dedup against real failure logs
[group: "validate"]
autofix-fixtures workflow=".github/workflows/reusable-auto-fix.yml":
    bash .github/tests/auto-fix-dedup/run.sh "{{workflow}}"

# Run reusable-claude.yml's failure-type and continuation-comment steps against fixtures
[group: "validate"]
claude-failure-type workflow=".github/workflows/reusable-claude.yml":
    bash .github/tests/claude-failure-type/run.sh "{{workflow}}"

# Run reusable-auto-merge-image-updater.yml's merge-retry step against stub gh
[group: "validate"]
automerge-retry:
    bash .github/tests/auto-merge-retry/run.sh

# Run reusable-changelog-review.yml's publish step against a stub gh
[group: "validate"]
changelog-publish workflow=".github/workflows/reusable-changelog-review.yml":
    bash .github/tests/changelog-review-publish/run.sh "{{workflow}}"

# Run reusable-changelog-review.yml's token-usage summary against its fixtures
[group: "validate"]
changelog-usage workflow=".github/workflows/reusable-changelog-review.yml":
    bash .github/tests/changelog-review-usage/run.sh "{{workflow}}"

# Check reusable-container-release.yml derives every image tag from the stripped version
[group: "validate"]
container-release-tags:
    bash .github/tests/container-release-tags/run.sh

# Run reusable-bun-ci.yml's extracted steps against stub bun, and the repo-wide inline-input baseline
[group: "validate"]
bun-ci:
    bash .github/tests/bun-ci/run.sh

# Run reusable-auto-resolve-conflicts.yml's resolve/build/publish steps against git fixtures
[group: "validate"]
auto-resolve-fixtures workflow=".github/workflows/reusable-auto-resolve-conflicts.yml":
    bash .github/tests/auto-resolve-stacked/run.sh "{{workflow}}"

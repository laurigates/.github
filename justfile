# laurigates/.github - Community health files & reusable workflows
# Run `just` or `just help` to see available recipes

set positional-arguments

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

####################
# Validation
####################

# Validate YAML syntax of all workflows
[group: "validate"]
lint:
    #!/usr/bin/env bash
    set -euo pipefail
    errors=0
    for f in .github/workflows/*.yml; do
        if ! python3 -c "import yaml; yaml.safe_load(open('$f'))" 2>/dev/null; then
            echo "INVALID: $f"
            errors=$((errors + 1))
        fi
    done
    if [[ $errors -eq 0 ]]; then
        echo "All workflow files are valid YAML."
    else
        echo "$errors file(s) have YAML errors."
        exit 1
    fi

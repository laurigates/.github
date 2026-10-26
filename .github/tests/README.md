# Workflow tests

`bash .github/tests/run.sh` (or `just test`) runs every `.github/tests/<name>/run.sh` in sorted order; `just test <name> ...` runs only the named ones. CI runs the same runner in `.github/workflows/lint.yml`. The runner fails when it discovers zero tests, and when it ran fewer tests than it discovered. Each test runs with stdin from `/dev/null`, so a test cannot read input the runner gave it (the `runner` test pins this).

Conventions for a new test:

- **Path and shape.** `.github/tests/<name>/run.sh`, `#!/usr/bin/env bash`, `set -euo pipefail`, `cd "$(git rev-parse --show-toplevel)"`, no arguments required (a test that takes a workflow path defaults it). Exit non-zero on any failure and print `PASS: <name> (<n> assertion(s))` as the last line on success; the runner reports an exit-0 test without a last line starting `PASS: ` as FAIL, because a test that stopped before asserting anything is otherwise indistinguishable from a pass.
- **Tools.** bash, git, yq (mikefarah v4), python3 stdlib, jq, curl: what `ubuntu-slim` ships. No PyYAML, no Docker.
- **Extract the shipped text.** Pull the `run:` body, `if:` expression, or input list out of the workflow file with yq/awk/sed and exercise that. A retyped copy is not the code under test.
- **Stub CLIs visibly.** Put stubs (`gh`, `npx`, …) first on `PATH`, `chmod +x` them, and have each print a sentinel the real tool never would; fail the test if the sentinel is missing, because a non-executable stub silently lets the real tool run.
- **Scan the class, not the file.** Loop over every `reusable-*.yml` and `reusable-*.yaml` (GitHub accepts both), so a future workflow that reintroduces the defect is caught. Assert each scan found at least one item before checking items.
- **No pipe into `grep -q` under `pipefail`.** `grep -q` exits on its first match, the producer then fails with "Broken pipe", and `pipefail` reports the match as a failure, intermittently. Use a here-string (`grep -Fq "$needle" <<<"$haystack"`) or `grep ... >/dev/null`.
- **Prove it has teeth.** Before opening the PR, run the test against the pre-fix tree (or a scratch copy with the defect reintroduced) and record that it fails with the expected message. A test that is green on both trees pins nothing.

# laurigates/.github

Default community health files and reusable GitHub Actions workflows for
[@laurigates](https://github.com/laurigates) repositories.

## What's here

| Path | Purpose |
|------|---------|
| `profile/README.md` | Profile shown on [github.com/laurigates](https://github.com/laurigates) |
| `CODE_OF_CONDUCT.md` | Default code of conduct for all repos |
| `CONTRIBUTING.md` | Default contribution guidelines for all repos |
| `SECURITY.md` | Security vulnerability reporting policy |
| `SUPPORT.md` | Where to get help |
| `.github/ISSUE_TEMPLATE/` | Default issue templates for all repos |
| `.github/PULL_REQUEST_TEMPLATE.md` | Default PR template for all repos |
| `.github/workflows/reusable-*.yml` | Reusable workflows callable from any repo |

The root files are defaults for every repository; a repo overrides one by
providing its own copy. `LICENSE` cannot be a default and stays per-repo.

## Quick start

Call a reusable workflow from a job in your repo:

```yaml
jobs:
  release-please:
    uses: laurigates/.github/.github/workflows/reusable-release-please.yml@main
```

Each workflow file declares its inputs and secrets under `on.workflow_call`.

## Documentation

| Page | Covers |
|------|--------|
| [Reusable workflows](docs/workflows.md) | Every reusable workflow by group, with a caller example |
| [Releases](docs/releases.md) | Merge method and `merge:*` labels, missed-release guard, squash commit parse check, finding the release PR |
| [Issue labels](docs/issue-labels.md) | What each label means, who sets and clears it, automatic labelling |
| [Bun CI](docs/bun-ci.md) | `reusable-bun-ci.yml` inputs and caveats |
| [Container signing](docs/container-signing.md) | Verifying cosign signatures, opting out |

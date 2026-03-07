# laurigates/.github

Default community health files and reusable GitHub Actions workflows for [@laurigates](https://github.com/laurigates) repositories.

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

## Reusable Workflows

Call these from any repo using `uses: laurigates/.github/.github/workflows/<name>.yml@main`.

### Infrastructure

| Workflow | Description |
|----------|-------------|
| `reusable-container-build.yml` | PR phase: build and push `:next-{version}` pre-release image to GHCR |
| `reusable-container-release.yml` | Release phase: promote pre-built image to semver tags (or fallback rebuild) + Trivy scan |
| `reusable-release-please.yml` | Automated releases via release-please |
| `reusable-auto-merge-image-updater.yml` | Auto-merge ArgoCD Image Updater PRs |
| `reusable-fix-release-conflicts.yml` | Auto-resolve release-please merge conflicts |
| `reusable-renovate.yml` | Dependency updates via Renovate |
| `reusable-claude.yml` | Claude Code @-mention support in issues and PRs |

### Security (Claude-powered)

| Workflow | Description |
|----------|-------------|
| `reusable-security-secrets.yml` | Detect leaked secrets and credentials |
| `reusable-security-deps.yml` | Dependency vulnerability audit |
| `reusable-security-owasp.yml` | OWASP Top 10 static analysis |

### Quality (Claude-powered)

| Workflow | Description |
|----------|-------------|
| `reusable-quality-code-smell.yml` | Code smell and anti-pattern detection |
| `reusable-quality-async.yml` | Async pattern validation |
| `reusable-quality-typescript.yml` | TypeScript strictness analysis |

### Accessibility (Claude-powered)

| Workflow | Description |
|----------|-------------|
| `reusable-a11y-aria.yml` | ARIA pattern correctness |
| `reusable-a11y-wcag.yml` | WCAG 2.1 compliance check |

## Usage Example

```yaml
# In your repo's .github/workflows/container-build.yml
name: Build and release container

on:
  push:
    tags: ['my-app-v*.*.*']
  pull_request:
    branches: [main]

jobs:
  build:
    if: startsWith(github.head_ref, 'release-please--branches--main')
    uses: laurigates/.github/.github/workflows/reusable-container-build.yml@main
    with:
      image-name: laurigates/my-app

  release:
    if: github.event_name == 'push'
    uses: laurigates/.github/.github/workflows/reusable-container-release.yml@main
    with:
      image-name: laurigates/my-app
      tag-prefix: my-app-v

  security:
    if: github.event_name == 'pull_request'
    uses: laurigates/.github/.github/workflows/reusable-security-owasp.yml@main
    secrets:
      CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

## Container Signing

Release images are signed with [Sigstore cosign](https://docs.sigstore.dev/) using keyless mode (OIDC identity from GitHub Actions). Signatures are recorded in the [Rekor](https://docs.sigstore.dev/logging/overview/) public transparency log.

### Verifying signatures

```bash
cosign verify \
  --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
  --certificate-identity-regexp='https://github.com/laurigates/' \
  ghcr.io/laurigates/my-app:1.2.3
```

### Opting out

Pass `enable-signing: false` to the release workflow:

```yaml
uses: laurigates/.github/.github/workflows/reusable-container-release.yml@main
with:
  image-name: laurigates/my-app
  tag-prefix: my-app-v
  enable-signing: false
```

## Community Health Files

Files at the root of this repo serve as defaults for all [@laurigates](https://github.com/laurigates) repositories. Individual repos can override any of them by providing their own copy.

Files that **cannot** be defaults (must be per-repo): `LICENSE`

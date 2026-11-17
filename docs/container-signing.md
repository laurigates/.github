# Container Signing

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

---
paths:
  - ".github/workflows/reusable-container-build.yml"
  - ".github/workflows/reusable-container-release.yml"
  - ".github/actions/scan-image/**"
  - ".github/tests/container-*/**"
  - "docs/container-signing.md"
---

# Container Build/Release (build-once/promote pattern)

The container workflows implement a two-phase pattern:

1. **`reusable-container-build.yml`** (PR phase) — builds and pushes a `:next-{version}` pre-release image to GHCR during the release-please PR
2. **`reusable-container-release.yml`** (tag phase) — resolves a single release *candidate* (promoted `:next-{version}` digest, or a rebuild), scans it, and only then creates the release tags. Optional cosign keyless signing via Sigstore

The version is extracted from the version file (default: `package.json`) during build, and from the git tag (stripping `tag-prefix`) during release. The release tags derive from that stripped version alone, so a `tag-prefix` that does not prefix the release tag fails the run. `.github/tests/container-release-tags/run.sh` (`just container-release-tags`) pins this.

## The vulnerability scan is a publication gate, not a report

The release job's invariant: **exactly one step creates a release tag, it has no `if:`, and the step immediately before it is the scan.** The scan's subject is a digest resolved by a step that also has no `if:` and hard-fails when it cannot resolve one, so both the promote and the rebuild path are covered by construction rather than by a condition someone can get wrong.

Six things not to re-derive:

- **The rebuild path pushes to `:next-{version}`, never to `meta.outputs.tags`.** Pushing the release tags from `docker/build-push-action` is what made the old scan unable to gate anything — the artifact was already published by the time it ran. Release tags are applied by `docker buildx imagetools create` from the scanned digest
- **The scan lives in `.github/actions/scan-image` and must be referenced fully-qualified** (`laurigates/.github/.github/actions/scan-image@main`). A `./`-relative `uses:` inside a reusable workflow resolves against the *caller's* checkout and fails in every consumer. It enumerates platform manifests from the image's own index, so a multi-arch caller's arm64 layers are scanned without anyone passing `platforms` twice
- **`--exit-code 13`, not `1`.** Trivy exits with the requested code for findings (`types.ExitError`) and `1` for everything else (`log.Fatal`), so `1` makes a DB-pull failure indistinguishable from a real CVE — and the natural response to the former is to switch the gate off. Confirmed on the pinned `v0.70.0` binary
- **The promote wait and the digest resolution are the same step, and the digest comes out of the wait's own probe.** `pr-image` waits for the PR-phase build (issue #51) and resolves `:next-{version}` to a digest in one place, which is the only read of that mutable tag in the job — freshness, the scan and publication all address the digest, so a concurrent PR-phase build moving the tag mid-job cannot change what ships. Editing the wait means preserving `PROBE_DIGEST`; editing the digest handling means preserving the bounded wait. `.github/tests/container-promote-wait/run.sh` (`just container-promote-wait`) runs the extracted step against stub `gh`, `docker` and a fake clock through every branch, including the two no live release has taken (issue #62): nothing in flight, whose notice must report a non-zero `run(s) inspected`, and an unreadable `/commits/{sha}/pulls`, which must warn and fall back to the per-workflow count
- **`scan-enforcement` is a validated string (`block`|`warn`), not a boolean.** An unrecognised value is a hard error at the top of the job; `continue-on-error: ${{ inputs.scan-enforcement == 'warn' }}` then means anything that is not exactly `warn` blocks. `warn` publishes *and* fails the job, reproducing the pre-gate outcome rather than swallowing the failure into a green run
- **A promoted single-manifest candidate is published inside a new index.** The PR-phase build pushes `:next-{version}` with provenance and SBOM off, so the candidate is a plain image manifest, and `imagetools create` wraps it in an index with its own digest (issue #180). The `verify` step therefore passes a tag that resolves to the scanned digest *or* to an index whose only entry is the scanned digest (read by digest, not by tag), requires every tag to resolve to one digest, and writes it as `digest`; `cosign-sign` signs the candidate and, when it differs, that index, because `cosign verify <tag>` resolves the tag to the index. `.github/tests/container-release-verify/run.sh` runs both extracted steps against a stub `docker` and `cosign`

The PR-phase build's scan is **advisory by default** (`scan-mode: advisory|block|off`) and is not the gate: a CVE published against an unchanged base would otherwise block every unrelated release, and the rebuild path exists precisely when the PR image is not what ships. `scan-mode` is validated at the top of the build job for the same reason `scan-enforcement` is — its `continue-on-error: ${{ inputs.scan-mode != 'block' }}` fails *open*, so an unvalidated `blocking`/`enforce`/`true` would silently downgrade a caller's blocking check to advisory.

## What a blocked release looks like in a consumer

Read from laurigates/pal-mcp-server's tag-push runs (issue #62). Between v11.0.0 and v11.9.0 the gate blocked 8 of 12 releases, on the promote path (v11.9.0, `Total: 4 (HIGH: 4, CRITICAL: 0)`) and on the rebuild path (v11.8.1, `Total: 11 (HIGH: 8, CRITICAL: 3)`). Three things follow for a caller:

- **A block leaves the git tag and the GitHub Release in place with no image.** `:next-{version}` is the only reference to that build, and `latest` stays on the last release that passed. The job summary's `Publication: BLOCKED` line renders, because the scan step still writes `result=findings` before it fails
- **Re-running the job cannot clear it.** The re-run scans the image built from the same tag, which carries the same lockfile. The fix is a refreshed lockfile or base image on the default branch and a new patch release
- **The fix often lands under a hidden commit type.** A Renovate lock refresh is `chore(deps)`, which opens no release PR, so the clean lock stays unpublished until the next `feat` or `fix`. pal-mcp-server cut 11.8.2 and 11.9.1 with a `Release-As:` footer for this reason (`.rulesync/rules/commit-and-release.md`)

The release PR's `build / build` job scans `:next-{version}` before the merge, and its log shows the result. That scan covers the same image the tag run promotes when the build context is unchanged. A lockfile audit on every PR (pip-audit, or `reusable-security-deps.yml`'s osv-scanner job) reports the finding earlier still.

# Releases

## Publishing

Merge the release changes into `main`, then tag the desired merged commit:

```sh
git switch main
git pull --ff-only
git tag -a v0.1.0 -m 'resh v0.1.0'
git push origin v0.1.0
```

The `Release` workflow tests and builds on GitHub-hosted Apple Silicon and Intel
runners, packages the remote adapter, and publishes these assets:

- `resh-macos-arm64.tar.gz`
- `resh-macos-x86_64.tar.gz`
- `resh-remote.tar.gz`
- `install.sh`
- `checksums.txt`
- Sigstore signature bundles (`*.sigstore.json`)

Tags must point to a commit already merged into `main`. Tags with a suffix such
as `v0.1.0-rc.1` create prereleases; stable releases become the latest release.
The version and Actions run number are embedded in the macOS executable's plist.

All assets are uploaded to a draft before it is published. Enable **Settings →
General → Releases → Enable release immutability** in GitHub to lock the tag and
assets after publication. A failed draft upload can be retried by rerunning the
workflow; an already published release requires a new version.

The workflow also runs packaging checks on relevant pull requests, without
signing or publishing a release.

## Verifying build provenance

Every archive and the standalone installer receive a GitHub Artifact Attestation
in the job that builds them. The manifest is attested before publication. GitHub
OIDC supplies the workflow identity; Sigstore signs the provenance and records it
in a transparency log. Signing requires no personal signing key or repository
secret. Third-party Actions are pinned to commit SHAs.

With a current GitHub CLI, download a release and verify an archive **before
extracting or running it**:

```sh
tag=v0.1.0
gh release download "$tag" --repo CruelAddict/resh
commit=$(gh api "repos/CruelAddict/resh/commits/$tag" --jq .sha)
gh attestation verify resh-macos-arm64.tar.gz --repo CruelAddict/resh \
  --signer-workflow CruelAddict/resh/.github/workflows/release.yml \
  --source-ref "refs/tags/$tag" --source-digest "$commit" \
  --deny-self-hosted-runners
```

Use the Intel archive on Intel Macs, or verify `resh-remote.tar.gz` on a remote
host. The same command verifies `install.sh` or `checksums.txt` by changing the
filename. Signature bundles are included for consumers that need to retain the
signed provenance; GitHub CLI uses the repository's attestations by default.

Verification authenticates the archive digest, repository, workflow, tagged
source commit and GitHub-hosted builder. Code review and dependency security
remain part of assessing the software itself. These provenance signatures serve
a different purpose from Apple Developer ID signing and notarization; the native
executable currently has an ad-hoc macOS signature.

## Installation

From a verified, extracted macOS archive, run `bash install.sh`. Rex must already
be installed and running as the installing account.

The standalone installer also supports downloading and verifying an archive:

```sh
bash install.sh --version v0.1.0 --verify
```

For a one-command installation after the first stable release:

```sh
curl --proto '=https' --proto-redir '=https' -fsSL \
  https://github.com/CruelAddict/resh/releases/latest/download/install.sh | bash
```

This convenience command executes the installer delivered over HTTPS and checks
the archive's SHA-256. To authenticate the installer itself, download and verify
`install.sh` first using the provenance command above. Pass `--verify` to verify
the downloaded archive's provenance too. `--remote` installs only the Lua adapter.

## Homebrew

The public `CruelAddict/homebrew-tap` repository maintains the Homebrew package
separately. Its update workflow checks for a stable release hourly (or on manual
dispatch), verifies both macOS archives against this release workflow, and then
updates the formula's version and SHA-256 values. No cross-repository write token
is needed. Prereleases are excluded.

The tap publishes its first formula only after a real, immutable, attested stable
release exists. Homebrew owns the executable and resources; the package's caveats
explain the small, explicit Rex configuration step using Homebrew's stable opt
paths. Installing the formula does not edit the user's Rex configuration.

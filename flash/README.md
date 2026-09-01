# FLASH-Ghostty fork overlay

This directory owns configuration that belongs to the fork rather than to
Ghostty's shared core.

- `product.env` is the shell/CI product manifest.
- `../macos/Configurations/FlashGhostty.*.xcconfig` contains Xcode product
  identity by build configuration. The Xcode project attaches these files at
  project level for Debug, Release, and ReleaseLocal.
- `../macos/FlashGhostty-Info.plist`, `../macos/FlashGhostty.sdef`, and
  `../macos/Sources/App/FlashMainMenu.xib` isolate the fork's bundle metadata,
  scripting dictionary, and main menu from their upstream counterparts.
- `../macos/Sources/Flash/Configuration/FlashGhosttyDefaults.ghostty` contains
  product defaults loaded before the user's configuration. User values win.
- `verify-product-overlay.sh` rejects drift between the manifest, Xcode
  overlay, Swift runtime profile, and default config.

FLASH-Ghostty keeps runtime state separate from official Ghostty. On macOS its
primary configuration is
`~/Library/Application Support/com.flashghostty.app/config.ghostty`; the
product-scoped XDG fallback is `$XDG_CONFIG_HOME/flash-ghostty/config.ghostty`.
Caches, themes, crash state, and SSH state use the same `flash-ghostty`
filesystem namespace.

The project selects the matching overlay automatically. CI also passes it
explicitly as a drift check:

```sh
macos/build.nu \
  --configuration Debug \
  --xcconfig "$PWD/macos/Configurations/FlashGhostty.Debug.xcconfig" \
  --action build
```

Official Ghostty release workflows remain upstream-owned and repository-gated,
so they are inert in this fork. The fork uses
`.github/workflows/flash-release.yml`; update distribution stays disabled until
FLASH-Ghostty owns signing and update-feed infrastructure.

## Signed release-candidate runbook

The fork workflow builds, signs, notarizes, staples, and verifies a universal
macOS release candidate. It uploads the ZIP, dSYMs, checksums, build-input
manifest, and provenance manifest as GitHub Actions artifacts retained for 14
days. It does not create a GitHub Release, DMG, Appcast, or permanent download;
those are a separate distribution decision.

Before the first run:

1. Reconcile any releases distributed outside GitHub. Set
   `FLASH_GHOSTTY_RELEASE_VERSION` and a strictly increasing
   `FLASH_GHOSTTY_BUNDLE_VERSION` in `flash/release-metadata.env` on the protected
   release commit. Do not infer the bundle version from a CI run number.
2. Protect `main`, require the `macos` branch-validation check, and disable
   force-pushes and deletion. For two-person governance, also require one pull
   request approval.
3. Create the GitHub Environment `flash-release` and restrict deployment to
   protected `main`. For two-person governance, invite a second trusted
   collaborator, require that reviewer on the environment, and prevent
   self-review. A single-owner setup must explicitly accept the loss of this
   independent approval boundary.
4. Add these Environment variables:

   - `FLASH_MACOS_TEAM_ID`: the canonical 10-character Apple Team ID.
   - `FLASH_MACOS_CERTIFICATE_SHA256`: the lowercase SHA-256 fingerprint of
     the Developer ID Application leaf certificate in DER form.

5. Add these Environment secrets directly in the GitHub UI; never put their
   values in a commit, issue, log, or chat:

   - `FLASH_MACOS_CERTIFICATE`: base64-encoded `.p12` containing exactly one
     matching Developer ID Application identity and its private key.
   - `FLASH_MACOS_CERTIFICATE_PWD`: `.p12` password.
   - `FLASH_MACOS_CERTIFICATE_NAME`: full Developer ID Application identity
     name reported by Keychain.
   - `FLASH_MACOS_CI_KEYCHAIN_PWD`: a dedicated random password used only for
     the ephemeral CI keychain.
   - `FLASH_APPLE_NOTARIZATION_ISSUER`: App Store Connect API issuer UUID.
   - `FLASH_APPLE_NOTARIZATION_KEY_ID`: App Store Connect API key ID.
   - `FLASH_APPLE_NOTARIZATION_KEY`: raw `.p8` private-key contents.

Keep all nine names above exclusive to the `flash-release` Environment. Do not
duplicate them as repository-level variables or secrets: the workflow context
does not expose a value's scope, so preflight cannot distinguish such a
fallback from the intended Environment configuration.

The certificate pin can be calculated locally without exposing the private
key. Replace the placeholder with the exact Keychain identity name:

```sh
(
  set -e
  certificate_pem="$(mktemp -t flash-developer-id)"
  certificate_der="$(mktemp -t flash-developer-id-der)"
  trap 'rm -f "$certificate_pem" "$certificate_der"' EXIT
  security find-certificate \
    -c 'Developer ID Application: Example (TEAMID)' \
    -p \
    > "$certificate_pem"
  openssl x509 \
    -in "$certificate_pem" \
    -outform DER \
    -out "$certificate_der"
  shasum -a 256 "$certificate_der" | awk '{print $1}'
)
```

After the protected release commit is on `main`, dispatch the exact version
recorded in `flash/release-metadata.env`:

```sh
gh workflow run flash-release.yml --ref main -f version=vX.Y.Z
```

Before reserving the macOS build runner, a no-deployment preflight job checks
that all required `flash-release` variables and secrets are present. That job
does not check out repository content, invoke an action, or receive token
permissions. It projects only configured/not-configured booleans into the shell
environment and never prints secret values; the signing job still performs the
authoritative certificate, identity, and key validation. If preflight fails,
configure the missing values and use **Re-run all jobs**. Environment wait
timers and required reviewers apply separately to both preflight and the signing
job.

The workflow fails closed unless the source is protected `main`, the metadata
matches the dispatch input, and the Environment values are present. It imports
exactly one matching signing identity, selects it by certificate hash, checks
the configured SHA-256 pin, and re-extracts the embedded leaf certificate from
every signed Mach-O slice before notarization. If signing or notarization fails,
GitHub's **Re-run failed jobs** action reuses and revalidates the exact unsigned
input from the successful build through a content-checked cache; the separately
uploaded one-day artifact remains a short-lived audit copy. If that cache has
been evicted, use **Re-run all jobs** to rebuild it. The cache contains no
signing credentials. After downloading the final artifact, retain the checksum
and provenance files with the release candidate and verify the app again before
distribution:

```bash
shasum -a 256 -c flash-ghostty-macos-universal-SHA256SUMS.txt
ditto -x -k flash-ghostty-macos-universal.zip .
codesign --verify --deep --strict --all-architectures --verbose=2 FLASH-Ghostty.app
xcrun stapler validate -v FLASH-Ghostty.app
spctl --assess --type execute --verbose=4 FLASH-Ghostty.app
(
  set -e
  set -o pipefail
  manifest="$(mktemp -t flash-artifact-files)"
  trap 'rm -f "$manifest"' EXIT
  find FLASH-Ghostty.app -type f -print0 > "$manifest"
  mach_o_count=0
  while IFS= read -r -d '' candidate; do
    candidate_type="$(file -b "$candidate")"
    if grep -q 'Mach-O' <<< "$candidate_type"; then
      ((mach_o_count += 1))
      architectures="$(
        lipo -archs "$candidate" \
          | tr ' ' '\n' \
          | LC_ALL=C sort \
          | paste -sd ' ' -
      )"
      test "$architectures" = "arm64 x86_64"
    fi
  done < "$manifest"
  test "$mach_o_count" -gt 0
)
```

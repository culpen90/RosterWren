# Releasing RosterWren

RosterWren releases are built and published by `.github/workflows/release.yml`. The workflow runs the app tests and release-configuration tests before it can create a tag or GitHub Release.

## Version contract

The repository starts at `0.1.0`. Because no historical tag exists, the first successful release workflow creates `v0.1.0` with the complete artifact set. Releases are assembled as drafts, their GitHub asset digests are matched against the final local files, and only then are they published. GitHub immutable releases are enabled for the repository; after publication the workflow verifies that GitHub reports the release immutable, locking its assets and associated tag.

Before calculating another version, the workflow reconciles every stable tag reachable from `main`. A failed draft is rebuilt from the exact tagged commit, its unpublished assets are replaced, reverified, and published. Semantic Release then continues in the same run, so commits made after the recovered tag are not left waiting for another push. An incomplete release that is already public fails closed instead of mutating published binaries. Unexpected, malformed, prerelease, or unmerged `v` tags also fail closed so they cannot silently change the version baseline.

After that bootstrap, Semantic Release evaluates Conventional Commits on `main`:

| Commit | Release |
| --- | --- |
| `fix:`, `perf:`, or `revert:` | Patch |
| `feat:` | Minor |
| `type!:` or `BREAKING CHANGE:` | Major |
| `build:`, `chore:`, `ci:`, `docs:`, `refactor:`, `style:`, `test:` | None |

The tag is `vX.Y.Z`. The same `X.Y.Z` value is injected into the built app's `CFBundleShortVersionString`; the GitHub Actions run number becomes `CFBundleVersion`. Tags and releases are published only from `main`, and up to 100 concurrent release runs queue behind the active run rather than replacing one another.

## Release contents

Every release contains:

- `RosterWren-X.Y.Z-macOS-universal.dmg`, with the app and an Applications shortcut.
- `RosterWren-X.Y.Z-macOS-universal.zip`, for a direct app download.
- `RosterWren-X.Y.Z-dSYMs.zip`, for crash symbolication.
- `RosterWren-X.Y.Z-SHA256SUMS.txt`, generated after all signing, notarization, and stapling.
- Generated GitHub Release notes. GitHub also supplies source archives.

The package script verifies the embedded version/build, requires both `arm64` and `x86_64`, checks the code signature, validates the DMG and ZIPs, and then calculates checksums over the final bytes.

## Developer ID signing and notarization

The workflow supports a complete Developer ID and App Store Connect API-key path. Configure all six GitHub Actions secrets together:

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE_P12_BASE64` | Base64-encoded Developer ID Application `.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12` |
| `MACOS_SIGNING_IDENTITY` | Exact identity, such as `Developer ID Application: Example (TEAMID)` |
| `APPLE_API_KEY_P8_BASE64` | Base64-encoded App Store Connect API `.p8` key |
| `APPLE_API_KEY_ID` | 10-character uppercase App Store Connect API key ID |
| `APPLE_API_ISSUER_ID` | UUID-form App Store Connect API issuer ID |

The workflow imports the certificate into a temporary keychain, signs with the hardened runtime and a trusted timestamp, notarizes the app, staples it before creating the direct ZIP, signs/notarizes/staples the DMG, and removes the temporary credentials even after a failure. GitHub injects the original secret environment variables only into the setup step; the unlocked temporary keychain and decoded API-key file remain available to the later packaging steps until cleanup.

Partial or absent signing configuration fails before packaging by default. For a development-only repository, a maintainer can set the repository variable `ALLOW_ADHOC_RELEASES` to the exact value `true`; this permits ad-hoc hardened-runtime packages, skips notarization, and adds a visible warning to the release notes. Configure the complete secret set before treating downloads as normal Gatekeeper-ready public releases.

## Local verification

Use Node 24, Xcode 26.6, and XcodeGen 2.45.4. The workflow selects the exact Xcode path and installs the checksum-pinned XcodeGen archive rather than following a rolling Homebrew formula.

```sh
npm ci --ignore-scripts
npm test
make test
make app VERSION=0.1.0 BUILD_NUMBER=1
cd dist
shasum -a 256 -c RosterWren-0.1.0-SHA256SUMS.txt
```

On a developer Mac, `make app` automatically selects the first valid Apple Development identity so TCC permissions such as Accessibility remain associated with the app across rebuilds. Set `MACOS_DEVELOPMENT_SIGNING_IDENTITY` to a certificate name or SHA-1 hash to choose one explicitly. If none is available, the package is ad-hoc signed and the script prints a warning; that fallback is unsuitable for testing permission persistence across builds. `ROSTERWREN_SIGNING_MODE=adhoc` continues to force the explicitly warned CI fallback and never auto-selects a local certificate.

Do not disable immutable releases or create release tags by hand after the bootstrap. Use Conventional Commits and let the release workflow own version calculation, tagging, notes, packaging, and publication.

On an exact `vX.Y.Z` checkout, plain `make app` derives `X.Y.Z` from the tag. On an untagged development checkout it uses `MARKETING_VERSION` from `project.yml`; `VERSION=X.Y.Z` remains available as an explicit override.

# Updates and releases

Tauross uses Sparkle 2.10.1 for manual and automatic update checks. Update installation always requires user confirmation. The app does not send Sparkle system profiling data.

## Trust and hosting

- Bundle identifier: `com.tauross.mac`.
- Stable feed: `https://github.com/Duy-Company/tauross/releases/latest/download/appcast.xml`.
- `SUPublicEDKey` in `Config/Info.plist` identifies Tauross's dedicated Ed25519 signing key.
- Both the appcast and the update ZIP must have valid signatures. Verification is required before extraction, and unsigned-feed fallback is disabled.
- The ZIP URL is pinned to the immutable versioned GitHub release; the feed URL follows the latest stable release.
- Current packages use ad hoc macOS signatures. They are not Developer ID signed or notarized. Adding notarization later requires the owner's Apple Developer credentials and changes to the signing step.

The private update key must never be committed, printed in CI logs, or shared with another application. The original is stored in the maintainer's macOS Keychain under account `com.tauross.mac`. Keep a separate secure backup through your normal key-management process.

## One-time GitHub Actions signing setup

The release workflow needs a repository secret named `SPARKLE_PRIVATE_KEY` in **Duy-Company/tauross**. After resolving Sparkle and verifying the public key, an authorized maintainer can run:

```sh
./Scripts/configure-updates.sh
```

This script exports Tauross's private key into a protected temporary file, transfers it to the repository's encrypted Actions secret through `gh`, and deletes the temporary file. The key remains in the local Keychain. Run this only when you authorize GitHub Actions for this repository to hold and use that signing key.

## Release a new version

1. Set both `CFBundleShortVersionString` and `CFBundleVersion` in `Config/Info.plist` to the same increasing version, e.g. `1.0.1`.
2. Add `release-notes/v1.0.1.md` and update user-facing documentation if needed.
3. Run the tests and `python3 Scripts/check-release.py`.
4. Commit and push the source, then create and push an annotated tag matching the version:

```sh
git tag -a v1.0.1 -m 'Tauross 1.0.1'
git push origin main v1.0.1
```

The tag starts `.github/workflows/macos.yml`, which:

- Checks the version, bundled binaries, pinned dependencies, and update settings.
- Runs unit tests and signed-feed/archive tampering tests.
- Builds a universal macOS app with all runtime dependencies embedded.
- Creates a ZIP, a DMG with an Applications shortcut, and SHA-256 checksums.
- Signs the appcast and ZIP with the repository secret and independently verifies them against the app's public key.
- Publishes a stable GitHub Release only after every check passes and every asset is uploaded.

Main-branch pushes and pull requests run checks/builds without accessing the signing secret or publishing a release. Release notes are embedded in the signed feed. Published download assets are not replaced by workflow reruns; incomplete draft uploads can be retried.

## Local packaging and verification

```sh
RELEASE_TAG=v1.0.0 ./Scripts/build-release.sh
python3 Scripts/create-appcast.py
swift -module-cache-path build/test-cache Scripts/verify-update.swift \
  dist/appcast.xml dist/Tauross-1.0.0-macos-universal.zip Config/Info.plist
```

Local appcast generation uses the Tauross key in Keychain. CI uses `SPARKLE_PRIVATE_KEY` via standard input; it never puts the key in a command-line argument.

After publishing, download the public ZIP/feed/checksums and verify their exact bytes. A successful local build or a pushed tag alone does not prove that in-app updates are available.

# Bundled dependencies

| Artifact | Version | Source used for this checkout | SHA-256 |
|---|---|---|---|
| `Tauross/Resources/Tools/adb` | 35.0.2-12147458 | Installed Google Android SDK `platform-tools/adb` | `9e78ca23f20ce357d156704d0eb706f90056d15310524881a1aec532be3acec3` |
| `Tauross/Resources/Tools/scrcpy-server` | 3.3.4 | Installed Homebrew scrcpy 3.3.4, upstream Genymobile | `8588238c9a5a00aa542906b6ec7e6d5541d9ffb9b5d0f6e1bc0e365e2303079e` |

Runtime does not depend on either installation. Both artifacts are copied into the app's resources. The adb binary is universal (arm64 and x86_64); the scrcpy server is Android DEX/JAR. macOS frameworks are linked from the OS. No third-party Swift packages are fetched during builds.

ADB notices: `Tauross/Resources/Licenses/Android-NOTICE.txt`.
scrcpy Apache 2.0 license: `Tauross/Resources/Licenses/scrcpy-LICENSE`.

Upstream: [ADB source](https://android.googlesource.com/platform/packages/modules/adb/), [Android Platform Tools](https://developer.android.com/tools/releases/platform-tools), [scrcpy v3.3.4](https://github.com/Genymobile/scrcpy/releases/tag/v3.3.4).

`Scripts/build.sh` ad-hoc signs the embedded ADB copy, which changes its file checksum in the built app. The checksums above identify the source artifacts in this repository.

## Update framework

**Sparkle 2.10.1** is fetched at build time from the official repository, pinned in `Tauross.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` to revision `ab7d71291238df6e0492143b120c9b696a35f603`. SwiftPM verifies its binary artifact checksum. The framework and its updater helpers are embedded in the shipped app; end users do not install it separately.

Sparkle's license is bundled at `Tauross/Resources/Licenses/Sparkle-LICENSE.txt`. See [Sparkle 2.10.1](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.1).

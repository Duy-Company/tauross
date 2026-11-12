#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
configuration="${1:-Debug}"
xcodebuild -project Tauross.xcodeproj -scheme Tauross -configuration "$configuration" \
  -destination 'generic/platform=macOS' -derivedDataPath build/DerivedData \
  -clonedSourcePackagesDirPath build/SourcePackages \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
app="build/DerivedData/Build/Products/$configuration/Tauross.app"
# Sign the nested ADB executable before the enclosing bundle. No Homebrew or external dylibs.
codesign --force --sign - --timestamp=none "$app/Contents/Resources/Resources/Tools/adb"
framework="$app/Contents/Frameworks/Sparkle.framework"
test -f "$framework/Versions/B/Sparkle"
# Xcode strips headers on embed; reseal the framework, preserving signed helpers inside it.
codesign --force --sign - --timestamp=none "$framework"
codesign --verify --deep --strict "$framework"
codesign --force --sign - --timestamp=none "$app"
codesign --verify --deep --strict "$app"
echo "Built: $PWD/$app"

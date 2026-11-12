#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 Scripts/check-release.py
./Scripts/build.sh Release

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Config/Info.plist)
APP='build/DerivedData/Build/Products/Release/Tauross.app'
lipo "$APP/Contents/MacOS/Tauross" -verify_arch arm64 x86_64
lipo "$APP/Contents/Resources/Resources/Tools/adb" -verify_arch arm64 x86_64
python3 Scripts/check-release.py --app "$APP"
mkdir -p dist
ZIP="Tauross-$VERSION-macos-universal.zip"
DMG="Tauross-$VERSION-macos-universal.dmg"
rm -f "dist/$ZIP" dist/appcast.xml
ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/$ZIP"

STAGING=$(mktemp -d "${TMPDIR:-/tmp}/tauross-release.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/Tauross.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Tauross $VERSION" -srcfolder "$STAGING" -ov -format UDZO "dist/$DMG"
hdiutil verify "dist/$DMG"
(
  cd dist
  shasum -a 256 "$ZIP" "$DMG" > SHA256SUMS.txt
)
echo "Release $VERSION packaged in dist/"

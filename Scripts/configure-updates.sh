#!/bin/bash
# Transfer only Tauross's signing key from Keychain to its GitHub repository secret.
set -euo pipefail
cd "$(dirname "$0")/.."
TOOLS=${1:-build/SourcePackages/artifacts/sparkle/Sparkle/bin}
gh api user --silent > /dev/null
EXPECTED=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Config/Info.plist)
ACTUAL=$("$TOOLS/generate_keys" --account com.tauross.mac -p)
[[ "$ACTUAL" == "$EXPECTED" ]] || { echo 'Keychain signing identity does not match Tauross.' >&2; exit 1; }
umask 077
KEY_DIR=$(mktemp -d "${TMPDIR:-/tmp}/tauross-signing.XXXXXX")
trap 'rm -rf "$KEY_DIR"' EXIT
"$TOOLS/generate_keys" --account com.tauross.mac -x "$KEY_DIR/signing-key" > /dev/null
gh secret set SPARKLE_PRIVATE_KEY --repo Duy-Company/tauross < "$KEY_DIR/signing-key"
echo 'Tauross update signing secret configured. The original key remains in macOS Keychain.'

#!/usr/bin/env python3
"""Validate the version, pinned dependencies, and signed-update configuration."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re

ROOT = Path(__file__).resolve().parent.parent
FEED = 'https://github.com/Duy-Company/tauross/releases/latest/download/appcast.xml'
TOOL_HASHES = {
    'adb': '9e78ca23f20ce357d156704d0eb706f90056d15310524881a1aec532be3acec3',
    'scrcpy-server': '8588238c9a5a00aa542906b6ec7e6d5541d9ffb9b5d0f6e1bc0e365e2303079e',
}

def validate_info(info):
    version = info['CFBundleShortVersionString']
    assert re.fullmatch(r'\d+\.\d+\.\d+', version), 'Use a stable semantic version, e.g. 1.0.0'
    assert info['CFBundleVersion'] == version, 'Build and release versions must match'
    assert info['CFBundleIdentifier'] == 'com.tauross.mac'
    assert info['LSMinimumSystemVersion'] == '14.0'
    assert info['SUFeedURL'] == FEED
    assert len(base64.b64decode(info['SUPublicEDKey'], validate=True)) == 32
    for key in ['TaurossUpdatesEnabled', 'SUVerifyUpdateBeforeExtraction', 'SURequireSignedFeed']:
        assert info[key] is True, f'{key} must be enabled'
    for key in ['SUAutomaticallyUpdate', 'SUAllowsAutomaticUpdates', 'SUEnableSystemProfiling']:
        assert info[key] is False, f'{key} must be disabled'
    assert info['SUSignedFeedFailureExpirationInterval'] == 0, 'Never fall back to unsigned feeds'
    return version

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path)
    args = parser.parse_args()
    info = plistlib.loads((ROOT / 'Config/Info.plist').read_bytes())
    version = validate_info(info)
    if os.environ.get('RELEASE_TAG'):
        assert os.environ['RELEASE_TAG'] == f'v{version}', 'Tag does not match the app version'
    assert (ROOT / f'release-notes/v{version}.md').is_file(), 'Release notes are missing'
    for name, expected in TOOL_HASHES.items():
        assert hashlib.sha256((ROOT / f'Tauross/Resources/Tools/{name}').read_bytes()).hexdigest() == expected, f'Unexpected {name} artifact'
    assert os.access(ROOT / 'Tauross/Resources/Tools/adb', os.X_OK), 'Bundled ADB must be executable'
    lock = json.loads((ROOT / 'Tauross.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved').read_text())
    assert len(lock['pins']) == 1 and lock['pins'][0]['identity'] == 'sparkle'
    assert lock['pins'][0]['state']['version'] == '2.10.1', 'Unexpected Sparkle version'
    if args.app:
        bundled = plistlib.loads((args.app / 'Contents/Info.plist').read_bytes())
        validate_info(bundled)
        for key in info:
            if key.startswith('SU') or key in ['CFBundleVersion', 'CFBundleShortVersionString', 'TaurossUpdatesEnabled']:
                assert bundled.get(key) == info[key], f'Packaged metadata mismatch: {key}'
        for relative in ['Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle',
                         'Contents/Resources/Resources/Tools/adb', 'Contents/Resources/Resources/Tools/scrcpy-server',
                         'Contents/Resources/Resources/Licenses/Sparkle-LICENSE.txt']:
            assert (args.app / relative).is_file(), f'Missing bundled dependency: {relative}'
    print(f'Release {version}: version, dependencies, and update configuration verified.')

if __name__ == '__main__':
    main()

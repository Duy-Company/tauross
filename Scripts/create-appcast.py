#!/usr/bin/env python3
"""Generate and verify a signed Sparkle feed for one immutable GitHub release."""
import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path)
    parser.add_argument('--info', type=Path, default=ROOT / 'Config/Info.plist')
    parser.add_argument('--notes', type=Path)
    parser.add_argument('--tools', type=Path)
    parser.add_argument('--output', type=Path, default=ROOT / 'dist/appcast.xml')
    args = parser.parse_args()
    info = plistlib.loads(args.info.read_bytes())
    # The source plist is an Xcode template; archives contain its resolved value.
    if info.get('CFBundleIdentifier') == '$(PRODUCT_BUNDLE_IDENTIFIER)':
        info['CFBundleIdentifier'] = 'com.tauross.mac'
    if info.get('TaurossUpdatesEnabled') is not True:
        raise ValueError('The app must have in-app updates enabled before publishing its update feed.')
    version = info['CFBundleShortVersionString']
    if info['CFBundleVersion'] != version:
        raise ValueError('Use the release version for CFBundleVersion so Sparkle can order updates.')
    if os.environ.get('RELEASE_TAG', f'v{version}') != f'v{version}':
        raise ValueError('RELEASE_TAG does not match the app version.')
    name = f'Tauross-{version}-macos-universal.zip'
    archive = (args.archive or ROOT / 'dist' / name).resolve()
    if archive.name != name:
        raise ValueError(f'Expected archive name: {name}')
    with zipfile.ZipFile(archive) as zipped:
        bundled = plistlib.loads(zipped.read('Tauross.app/Contents/Info.plist'))
    for key in ['CFBundleIdentifier', 'CFBundleVersion', 'CFBundleShortVersionString',
                'SUPublicEDKey', 'SUFeedURL', 'SURequireSignedFeed', 'SUVerifyUpdateBeforeExtraction', 'TaurossUpdatesEnabled']:
        if bundled.get(key) != info.get(key):
            raise ValueError(f'Packaged app does not match expected metadata: {key}')
    notes = args.notes or ROOT / 'release-notes' / f'v{version}.md'
    if not notes.is_file():
        raise ValueError(f'Release notes are missing: {notes}')
    tools = args.tools
    if tools is None:
        tools = ROOT / 'build/SourcePackages/artifacts/sparkle/Sparkle/bin'
    if not (tools / 'generate_appcast').is_file():
        raise ValueError('Sparkle tools not found. Build the app first or pass --tools.')
    secret = os.environ.get('SPARKLE_PRIVATE_KEY')
    if os.environ.get('CI') and not secret:
        raise ValueError('Set the SPARKLE_PRIVATE_KEY repository secret before publishing updates.')
    signing = ['--ed-key-file', '-'] if secret else ['--account', 'com.tauross.mac']
    args.output.parent.mkdir(parents=True, exist_ok=True)
    # Only the current ZIP is visible to generate_appcast, never old local dist files.
    with tempfile.TemporaryDirectory(prefix='tauross-appcast-') as directory:
        staging = Path(directory)
        shutil.copy2(archive, staging / name)
        shutil.copy2(notes, staging / f'{Path(name).stem}.md')
        subprocess.run([str(tools / 'generate_appcast'), *signing,
                        '--download-url-prefix', f'https://github.com/Duy-Company/tauross/releases/download/v{version}/',
                        '--embed-release-notes', '--maximum-deltas', '0', str(staging)],
                       input=secret, text=True, check=True)
        generated = staging / 'appcast.xml'
        # Never publish a feed whose signature doesn't match the key embedded in the app.
        subprocess.run(['swift', '-module-cache-path', str(ROOT / 'build/test-cache'),
                        str(ROOT / 'Scripts/verify-update.swift'), str(generated), str(archive), str(args.info.resolve())],
                       check=True)
        shutil.copy2(generated, args.output)
    checksums = args.output.parent / 'SHA256SUMS.txt'
    if checksums.is_file():
        lines = [line for line in checksums.read_text().splitlines()
                 if line.strip() and line.split()[-1] != args.output.name]
        lines.append(f'{hashlib.sha256(args.output.read_bytes()).hexdigest()}  {args.output.name}')
        checksums.write_text('\n'.join(lines) + '\n')
    print(f'Signed update feed: {args.output}')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        raise SystemExit(f'Cannot create update feed: {error}')

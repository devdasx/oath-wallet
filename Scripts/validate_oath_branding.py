#!/usr/bin/env python3
"""Check Oath artwork, all localized names, and the existing wallet identity.

Optionally pass --app "/path/to/Oath Wallet.app" to inspect the compiled product.
Branding/Oath Brand Kit is the canonical artwork. Home Screen icons preserve the
supplied masters with only their unused alpha channel removed for the App Store.
"""
import argparse
import json
import plistlib
import re
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'EVMWallet'
ASSETS = APP / 'Assets.xcassets'
KIT = ROOT / 'Branding/Oath Brand Kit'
# These are existing, real destinations, not display branding.
URL = re.compile(r'https?://[^\s]+|(?:care@|support@)?aperturex\.io|github\.com/devdasx/aperture', re.I)


def strings(path):
    return json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(path)]))


def validate(product=None):
    errors = []
    def check(condition, message):
        if not condition:
            errors.append(message)

    locales = sorted(APP.glob('*.lproj'))
    for locale in locales:
        for name in ('Localizable.strings', 'InfoPlist.strings'):
            values = strings(locale / name)
            for key, value in values.items():
                display_value = URL.sub('', value)
                # This release note explicitly explains the historical name change.
                if name == 'Localizable.strings' and key == 'settings.about.history.v400.identity':
                    check('Oath' in value, f'Missing current brand in rebrand history: {locale.name}')
                    display_value = re.sub(r'\baperture\b', '', display_value, flags=re.I)
                check(not re.search(r'\b(aperture|keymate)\b', display_value, re.I),
                      f'Retired display name: {locale.name}/{name}: {key}')
            expected = {'brand.name': 'Oath Wallet', 'brand.name.uppercase': 'OATH WALLET'} if name == 'Localizable.strings' else {'CFBundleDisplayName': 'Oath Wallet'}
            for key, value in expected.items():
                check(values.get(key) == value, f'Incorrect name: {locale.name}/{key}')

    mappings = {
        'BrandLogo.imageset/oath-mark-light.png': '02 Logo/Mark/oath-mark-light-bg-1600.png',
        'BrandLogo.imageset/oath-mark-dark.png': '02 Logo/Mark/oath-mark-dark-bg-1600.png',
        'OnboardingSplashLogo.imageset/oath-light.png': '01 App Icon/oath-app-icon-light-1024.png',
        'OnboardingSplashLogo.imageset/oath-dark.png': '01 App Icon/oath-app-icon-dark-1024.png',
        'WalletIdentityMark.imageset/oath-mark-solid-white.png': '02 Logo/Mark/oath-mark-solid-white-1600.png',
    }
    for destination, original in mappings.items():
        installed, supplied = ASSETS / destination, KIT / original
        check(installed.is_file() and supplied.is_file()
              and installed.read_bytes() == supplied.read_bytes(),
              f'Artwork differs from supplied Oath kit: {destination}')

    icon_check = subprocess.run(
        ['swift', str(ROOT / 'Scripts/prepare_app_store_icons.swift'), '--check'],
        cwd=ROOT, capture_output=True, text=True,
    )
    check(icon_check.returncode == 0, f'Home Screen icon validation failed: {icon_check.stderr.strip()}')

    for name in ('AppIcon.appiconset', 'BrandLogo.imageset', 'OnboardingSplashLogo.imageset', 'WalletIdentityMark.imageset'):
        directory = ASSETS / name
        catalog = json.loads((directory / 'Contents.json').read_text())
        expected = {'Contents.json'} | {image['filename'] for image in catalog['images']}
        check({path.name for path in directory.iterdir()} == expected, f'Orphaned or missing artwork in {name}')
    icons = json.loads((ASSETS / 'AppIcon.appiconset/Contents.json').read_text())['images']
    check(len(icons) == 3 and {image.get('appearances', [{}])[0].get('value', 'light') for image in icons} == {'light', 'dark', 'tinted'}, 'App icon appearances missing')

    info = plistlib.loads((APP / 'Info.plist').read_bytes())
    check(info['CFBundleDisplayName'] == 'Oath Wallet', 'Wrong base app name')
    check(info['NSUbiquitousContainers']['iCloud.com.aperture.wallet']['NSUbiquitousContainerName'] == 'Oath Wallet', 'Wrong iCloud display label')
    check('_aperture-xfer._tcp' in info['NSBonjourServices'], 'Existing transfer compatibility changed')
    entitlements = plistlib.loads((APP / 'EVMWallet.entitlements').read_bytes())
    check(entitlements['keychain-access-groups'] == ['$(AppIdentifierPrefix)com.aperture.wallet'], 'Existing Keychain access group changed')
    check('document.applicationName == "Aperture"' in (APP / 'WalletICloudDriveBackupStore.swift').read_text(), 'Existing backup read compatibility changed')
    check('applicationName = "Aperture"' in (APP / 'WalletAutomaticCloudBackupService.swift').read_text(), 'Encrypted backup identity changed')
    project = (ROOT / 'EVMWallet.xcodeproj/project.pbxproj').read_text()
    check(project.count('PRODUCT_BUNDLE_IDENTIFIER = com.aperture.wallet;') == 2, 'App bundle identifier changed')
    check(project.count('PRODUCT_NAME = "Oath Wallet";') == 2, 'Wrong product name')
    check(project.count('PRODUCT_MODULE_NAME = Aperture;') == 2, 'Existing Swift/App Intent identity changed')
    for scheme in (ROOT / 'EVMWallet.xcodeproj').rglob('*.xcscheme'):
        for ref in ET.parse(scheme).iter('BuildableReference'):
            if ref.get('BlueprintName') == 'Aperture':
                check(ref.get('BuildableName') == 'Oath Wallet.app', f'Wrong app product in {scheme.name}')

    if product:
        built = plistlib.loads((product / 'Info.plist').read_bytes())
        for key, value in {'CFBundleDisplayName': 'Oath Wallet', 'CFBundleName': 'Oath Wallet', 'CFBundleExecutable': 'Oath Wallet', 'CFBundleIdentifier': 'com.aperture.wallet'}.items():
            check(built.get(key) == value, f'Built {key} is incorrect')
        for locale in locales:
            check(strings(product / locale.name / 'InfoPlist.strings').get('CFBundleDisplayName') == 'Oath Wallet', f'Built localized name is incorrect: {locale.name}')
        check((product / 'Assets.car').is_file(), 'Compiled artwork catalog missing')
    if errors:
        raise SystemExit('\n'.join(errors))
    print(f'Oath Wallet verified: {len(locales)} locales, official light/dark/tinted artwork, and unchanged wallet identity.' + (' Compiled app verified.' if product else ''))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path)
    validate(parser.parse_args().app)


if __name__ == '__main__':
    main()

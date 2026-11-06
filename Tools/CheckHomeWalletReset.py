#!/usr/bin/env python3
"""Opt-in native Home scroll/backup sequencing check with synthetic wallet IDs.

Extracts the production list identity and backup appearance gate. Never opens
Oath, creates a real wallet, or accesses Keychain/network wallet services.
"""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]


def run(*args):
    return subprocess.run(args, check=True, text=True, capture_output=True, timeout=180).stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--simulator-check', action='store_true')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--home-source', type=Path, help='Pre-fix source for a negative control')
    args = parser.parse_args()
    if not args.simulator_check:
        parser.error('State the unresolved native layout concern before opting in.')
    args.output.mkdir(parents=True, exist_ok=True)
    home = (args.home_source or ROOT / 'OathAtmosphere/Home/OathHomeScreen.swift').read_text()
    start = home.index('    private var homeContent: some View {')
    end = home.index('.modifier(OathHomeScrollEdgeAppearance())', start)
    boundary = '\n            }'
    identity = home[home.rindex(boundary, start, end) + len(boundary):end]
    start = home.index('    private var walletNavigation: some View {')
    start = home.index('                .background {', start)
    appearance = home[start:home.index('                // Asset details', start)]
    fixture = (ROOT / 'Tools/HomeWalletResetRegression/Tests.swift').read_text()
    fixture = fixture.replace('// PRODUCTION_SCROLL_IDENTITY', identity)
    fixture = fixture.replace('// PRODUCTION_BACKUP_APPEARANCE', appearance)
    device = None
    with tempfile.TemporaryDirectory(prefix='oath-home-wallet-reset-') as directory:
        work = Path(directory)
        (work / 'Tests.swift').write_text(fixture)
        (work / 'App.swift').write_text('import SwiftUI\n@main struct ProbeApp: App { var body: some Scene { WindowGroup { Color.clear } } }\n')
        spec = {
            'name': 'HomeWalletReset', 'options': {'deploymentTarget': {'iOS': '17.0'}},
            'packages': {'OathNativeRefresh': {'path': str(ROOT / 'Packages/OathNativeRefresh')}},
            'settings': {'base': {'CODE_SIGNING_ALLOWED': 'NO', 'SWIFT_VERSION': '6.0', 'GENERATE_INFOPLIST_FILE': 'YES'}},
            'targets': {
                'HomeWalletReset': {'type': 'application', 'platform': 'iOS', 'sources': ['App.swift'],
                    'settings': {'base': {'PRODUCT_BUNDLE_IDENTIFIER': 'org.oathwallet.home-reset-probe', 'INFOPLIST_KEY_UILaunchScreen_Generation': 'YES'}}},
                'ResetTests': {'type': 'bundle.unit-test', 'platform': 'iOS',
                    'sources': ['Tests.swift', str(ROOT / 'OathAtmosphere/Shared/OathAutofocus.swift'),
                                str(ROOT / 'OathAtmosphere/Shared/OathAutofocusGate.swift'),
                                str(ROOT / 'OathAtmosphere/Home/OathHomeBodySurface.swift')],
                    'dependencies': [{'target': 'HomeWalletReset'}, {'package': 'OathNativeRefresh'}],
                    'settings': {'base': {'PRODUCT_BUNDLE_IDENTIFIER': 'org.oathwallet.home-reset-probe.tests'}}}},
            'schemes': {'HomeWalletReset': {'build': {'targets': {'HomeWalletReset': 'all', 'ResetTests': ['test']}},
                'test': {'targets': ['ResetTests']}}}}
        (work / 'project.yml').write_text(json.dumps(spec))
        run('xcodegen', 'generate', '--spec', str(work / 'project.yml'))
        try:
            device = run('xcrun', 'simctl', 'create', 'Oath Home Reset ' + uuid.uuid4().hex[:8],
                'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max', 'com.apple.CoreSimulator.SimRuntime.iOS-27-0')
            with (args.output / 'test.log').open('w') as log:
                result = subprocess.run(['xcodebuild', '-project', str(work / 'HomeWalletReset.xcodeproj'),
                    '-scheme', 'HomeWalletReset', '-destination', 'platform=iOS Simulator,id=' + device,
                    '-derivedDataPath', str(work / 'build'), '-parallel-testing-enabled', 'NO',
                    '-collect-test-diagnostics', 'never', '-resultBundlePath', str(args.output / 'Reset.xcresult'),
                    'test'], stdout=log, stderr=subprocess.STDOUT, timeout=600)
            result.check_returncode()
            print('PASS: LTR/RTL new-wallet header before backup, wallet switching, and same-wallet scroll preservation.')
        finally:
            if device:
                subprocess.run(['xcrun', 'simctl', 'shutdown', device], capture_output=True, timeout=60)
                subprocess.run(['xcrun', 'simctl', 'delete', device], check=True, capture_output=True, timeout=60)


if __name__ == '__main__':
    main()

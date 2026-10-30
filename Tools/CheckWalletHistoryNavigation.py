#!/usr/bin/env python3
"""Opt-in native tab/wallet regression with production navigation and synthetic receipts."""
from pathlib import Path
import argparse
import json
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
    parser.add_argument('--home-source', type=Path)
    args = parser.parse_args()
    if not args.simulator_check:
        parser.error('Identify the unresolved native navigation concern before opting into a simulator check.')
    args.output.mkdir(parents=True, exist_ok=True)
    home = (args.home_source or ROOT/'OathAtmosphere/Home/OathHomeScreen.swift').read_text()
    navigation = home[home.index('    private var historyNavigation: some View {'):home.index('    private var homeContent: some View {')]
    activity = (ROOT/'OathAtmosphere/Assets/OathChainActivityScreen.swift').read_text()
    destination = activity[activity.index('        .navigationDestination(isPresented:'):activity.index('        .task(id: OathHistoryObservationID')]
    probe = (ROOT/'Tools/WalletHistoryNavigationRegression/Probe.swift').read_text()
    probe = probe.replace('    // PRODUCTION_NAVIGATION', navigation).replace('        // PRODUCTION_DESTINATION', destination)
    device = None
    with tempfile.TemporaryDirectory(prefix='oath-wallet-history-navigation-') as temporary:
        work = Path(temporary)
        (work/'Probe.swift').write_text(probe)
        spec = {
            'name': 'WalletHistoryNavigationProbe', 'options': {'deploymentTarget': {'iOS': '26.0'}},
            'settings': {'base': {'CODE_SIGNING_ALLOWED': 'NO', 'SWIFT_VERSION': '6.0', 'GENERATE_INFOPLIST_FILE': 'YES'}},
            'targets': {
                'WalletHistoryNavigationProbe': {'type': 'application', 'platform': 'iOS', 'sources': [str(work/'Probe.swift')],
                    'settings': {'base': {'PRODUCT_BUNDLE_IDENTIFIER': 'org.oathwallet.history-navigation-probe', 'INFOPLIST_KEY_UILaunchScreen_Generation': 'YES'}}},
                'NavigationUITests': {'type': 'bundle.ui-testing', 'platform': 'iOS',
                    'sources': [str(ROOT/'Tools/WalletHistoryNavigationRegression/NavigationUITests.swift')],
                    'dependencies': [{'target': 'WalletHistoryNavigationProbe'}],
                    'settings': {'base': {'PRODUCT_BUNDLE_IDENTIFIER': 'org.oathwallet.history-navigation-probe.tests'}}}},
            'schemes': {'WalletHistoryNavigationProbe': {'build': {'targets': {'WalletHistoryNavigationProbe': 'all', 'NavigationUITests': ['test']}},
                'test': {'targets': ['NavigationUITests']}}}}
        (work/'project.yml').write_text(json.dumps(spec))
        run('xcodegen', 'generate', '--spec', str(work/'project.yml'))
        try:
            device = run('xcrun', 'simctl', 'create', 'Oath History Navigation '+uuid.uuid4().hex[:8],
                         'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max', 'com.apple.CoreSimulator.SimRuntime.iOS-27-0')
            with (args.output/'test.log').open('w') as log:
                result = subprocess.run(['xcodebuild', '-project', str(work/'WalletHistoryNavigationProbe.xcodeproj'),
                    '-scheme', 'WalletHistoryNavigationProbe', '-destination', 'platform=iOS Simulator,id='+device,
                    '-derivedDataPath', str(work/'build'), '-parallel-testing-enabled', 'NO', '-collect-test-diagnostics', 'never',
                    '-resultBundlePath', str(args.output/'Navigation.xcresult'), 'test'], stdout=log, stderr=subprocess.STDOUT, timeout=600)
            result.check_returncode()
            print('PASS: History and history-search discard receipts on wallet switches and preserve same-wallet navigation (synthetic wallets).')
        finally:
            if device:
                subprocess.run(['xcrun', 'simctl', 'shutdown', device], capture_output=True, timeout=60)
                subprocess.run(['xcrun', 'simctl', 'delete', device], check=True, capture_output=True, timeout=60)

if __name__ == '__main__':
    main()

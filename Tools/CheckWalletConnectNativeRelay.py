#!/usr/bin/env python3
"""Opt-in native relay check. Requires a user-authorized, booted simulator.
Build the dedicated scheme first. This runner never selects/boots a physical
device; only the explicitly provided simulator is installed/tested.
"""
import argparse, os, plistlib, subprocess, time
from pathlib import Path
from SimulatorAppPreflight import validate_simulator_app
parser = argparse.ArgumentParser()
parser.add_argument('--simulator', required=True)
parser.add_argument('--result', required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
os.chdir(root)
# Fail before installing or staging relay data when the simulator build cannot
# access its Keychain. Never work around this by weakening vault security.
app = Path('/tmp/oath-wc-derived/Build/Products/Debug-iphonesimulator/Oath Wallet.app')
validate_simulator_app(app, 'com.aperture.wallet')
subprocess.run(['xcrun','simctl','install',args.simulator,str(app)],check=True)
container = subprocess.check_output(['xcrun','simctl','get_app_container',args.simulator,'com.aperture.wallet','data'],text=True).strip()
fixture = Path(container)/'Documents/walletconnect-relay-fixture.json'
fixture.parent.mkdir(exist_ok=True)
fixture.unlink(missing_ok=True)
env = os.environ.copy()
env.setdefault('NODE_PATH','/tmp/oath-scanner-relay-check/node_modules')
with (root/'OathApp/Private/TokenRPC.plist').open('rb') as f:
    env['OATH_WC_PROJECT_ID'] = plistlib.load(f)['WalletConnectProjectID']
env['OATH_WC_FIXTURE_PATH'] = str(fixture)
with open('/tmp/oath-wc-native-peer.log','w') as log:
    peer = subprocess.Popen(['node','Tools/CheckWalletConnectNativeRelay.cjs'],env=env,stdout=log,stderr=log)
    try:
        for _ in range(120):
            if fixture.exists(): break
            if peer.poll() is not None: raise RuntimeError('Peer failed before pairing')
            time.sleep(.5)
        else: raise TimeoutError('Peer timed out before pairing')
        with open('/tmp/oath-wc-native-ui.log','w') as out:
            result = subprocess.run(['xcodebuild','-project','OathAtmosphere.xcodeproj','-scheme','OathWalletConnectLiveValidation',
                '-destination','platform=iOS Simulator,id='+args.simulator,'-derivedDataPath','/tmp/oath-wc-derived',
                '-resultBundlePath',args.result,'-parallel-testing-enabled','NO','-collect-test-diagnostics','never',
                'test-without-building'],stdout=out,stderr=out)
        if result.returncode: peer.terminate()
        try: status = peer.wait(timeout=30)
        except subprocess.TimeoutExpired: peer.terminate(); status = 1
        print('Native UI exit:',result.returncode,'Relay exit:',status)
        raise SystemExit(0 if result.returncode == status == 0 else 1)
    finally:
        if peer.poll() is None: peer.terminate()
        fixture.unlink(missing_ok=True)

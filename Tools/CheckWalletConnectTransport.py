#!/usr/bin/env python3
"""Host-only checks of the exact production URLSession socket implementation.

No simulator, wallet storage, signing or on-chain operations. The optional live
check uses two ephemeral identities and an isolated relay topic. Node dependencies
(`ws`, `@walletconnect/relay-auth` for --live) must be available through NODE_PATH.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument('--live', action='store_true')
parser.add_argument('--sdk', default=str(Path(__file__).resolve().parents[1] / 'Vendor/Reown'))
parser.add_argument('--scratch', default='/tmp/oath-wc-socket-host-build')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
fixtures = root / 'Tools/WalletConnectTransportValidation'
env = os.environ.copy()
env.setdefault('NODE_PATH', '/tmp/oath-scanner-relay-check/node_modules')
if args.live:
    with (root / 'OathApp/Private/TokenRPC.plist').open('rb') as file:
        env['OATH_WC_PROJECT_ID'] = plistlib.load(file)['WalletConnectProjectID']
    auth = subprocess.run(['node', str(fixtures / 'auth.cjs')], env=env, capture_output=True, check=False)
    if auth.returncode:
        raise SystemExit('Could not create isolated relay fixture authentication.')
    env['OATH_SOCKET_LIVE'] = auth.stdout.decode()
    del env['OATH_WC_PROJECT_ID']

with tempfile.TemporaryDirectory(prefix='oath-native-socket-') as temporary:
    work = Path(temporary)
    sources, tests = work / 'Sources/SocketTransport', work / 'Tests/SocketTransportTests'
    sources.mkdir(parents=True)
    tests.mkdir(parents=True)
    relay = work / 'Sources/RelayDispatcher'
    relay.mkdir(parents=True)
    sdk = Path(args.sdk) / 'Sources/WalletConnectRelay'
    for name in ['Dispatching.swift', 'SocketConnectionHandler/SocketConnectionHandler.swift',
                 'SocketConnectionHandler/WebSocket.swift', 'SocketStatusProvider.swift', 'NetworkMonitoring.swift']:
        (relay / Path(name).name).write_text((sdk / name).read_text().split('#if DEBUG')[0])
    shutil.copyfile(fixtures / 'DispatcherSupport.swift', relay / 'DispatcherSupport.swift')
    production = (root / 'OathAtmosphere/Scanner/OathWalletConnectTransport.swift').read_text()
    socket = production[production.index('struct OathWCSocketFactory:'):]
    (sources / 'Socket.swift').write_text('import Foundation\nimport RelayDispatcher\nimport OathDiagnostics\n' + socket)
    shutil.copyfile(fixtures / 'SocketTests.swift', tests / 'SocketTests.swift')
    shutil.copyfile(fixtures / 'DispatcherTests.swift', tests / 'DispatcherTests.swift')
    (work / 'Package.swift').write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "SocketTransport", platforms: [.macOS(.v14)],
 dependencies: [.package(path: DIAGNOSTICS)], targets: [
 .target(name: "RelayDispatcher", swiftSettings: [.swiftLanguageMode(.v5)]),
 .target(name: "SocketTransport", dependencies: ["OathDiagnostics", "RelayDispatcher"]),
 .testTarget(name: "SocketTransportTests", dependencies: ["SocketTransport", "OathDiagnostics", "RelayDispatcher"])],
 swiftLanguageModes: [.v6])
'''.replace('DIAGNOSTICS', json.dumps(str(root / 'Packages/OathDiagnostics'))))
    port_file = work / 'port'
    env['OATH_SOCKET_PORT_FILE'] = str(port_file)
    env['OATH_SOCKET_DIAGNOSTICS_FILE'] = str(work / 'diagnostics.json')
    peer = subprocess.Popen(['node', str(fixtures / 'server.cjs')], env=env,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(100):
            if port_file.exists():
                break
            if peer.poll() is not None:
                raise SystemExit('Loopback socket peer failed to start. Check Node dependencies.')
            time.sleep(.05)
        else:
            raise SystemExit('Loopback socket peer startup timed out.')
        env['OATH_SOCKET_TEST_PORT'] = port_file.read_text()
        result = subprocess.run(['swift', 'test', '--package-path', str(work), '--scratch-path', args.scratch],
                                env=env, timeout=180)
        raise SystemExit(result.returncode)
    finally:
        peer.terminate()
        try:
            peer.wait(timeout=5)
        except subprocess.TimeoutExpired:
            peer.kill()
            peer.wait()

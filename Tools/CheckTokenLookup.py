#!/usr/bin/env python3
"""Host regression checks for production multichain token search/RPC handling.

The iOS-only WalletCore keccak adapter is replaced by OathAnkr's equivalent.
Base58 adapters use the app's existing OathAnkr codecs on the host.
Presentation-only localization uses an English host shim; localization is not
under test here.
Optional --live reads real public contracts using bundled RPC configuration.
"""
import argparse, json, os, plistlib, shutil, subprocess, tempfile
from pathlib import Path
parser = argparse.ArgumentParser()
parser.add_argument('--live', action='store_true')
parser.add_argument('--all-networks', action='store_true', help='Live selected-token resolution on every supported token network')
parser.add_argument('--six-chains', action='store_true', help='Live discovery and public RPC fallback checks for the six new chains')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
env = os.environ.copy()
if args.live or args.all_networks or args.six_chains:
    with (root / 'OathApp/Private/TokenRPC.plist').open('rb') as file:
        env['OATH_TOKEN_LOOKUP_LIVE_KEY'] = plistlib.load(file)['AnkrAPIKey']
if args.six_chains:
    env['OATH_TOKEN_SIX_CHAINS'] = '1'
if args.all_networks:
    env['OATH_TOKEN_DISCOVERY_ADD_LIVE'] = '1'
    env['OATH_TOKEN_DISCOVERY_SEED'] = str(root / 'Packages/OathAnkr/Sources/OathAnkr/Resources/TokenDiscoverySeed.json')
with tempfile.TemporaryDirectory(prefix='oath-token-lookup-') as temporary:
    work = Path(temporary)
    sources, tests = work / 'Sources/TokenLookup', work / 'Tests/TokenLookupTests'
    sources.mkdir(parents=True); tests.mkdir(parents=True)
    for name in ['Tokens/OathTokenNetwork.swift', 'Tokens/OathTokenService.swift',
                 'Tokens/OathTokenSearchModel.swift', 'Import/OathImportCatalog.swift']:
        shutil.copyfile(root / 'OathAtmosphere' / name, sources / Path(name).name)
    codec = (root / 'OathAtmosphere/Tokens/OathTokenCodec.swift').read_text()
    (sources / 'OathTokenCodec.swift').write_text(codec.replace('import WalletCore', 'import OathAnkr')
        .replace('Hash.keccak256(data: Data(lower.utf8))', 'TronSendCrypto.keccak(Data(lower.utf8))'))
    (sources / 'HostBase58.swift').write_text('''import Foundation
import OathAnkr
enum Base58 {
 static func decode(string: String) -> Data? { try? TronIdentity.bytes(string) }
 static func decodeNoCheck(string: String) -> Data? { try? SolanaSendCrypto.decode(string) }
 static func encodeNoCheck(data: Data) -> String { SolanaSendCrypto.encode(data) }
}
''')
    (sources / 'HostLocalizer.swift').write_text('''// Presentation boundary only; token lookup/selection use production sources.
struct OathLocalizer {
 enum Key { case tokenBankStandard }
 func text(_ key: Key) -> String { "Bank token" }
 func invariant(_ value: String) -> String { value }
}
''')
    shutil.copyfile(root / 'Tools/TokenLookupValidation/TokenLookupTests.swift', tests / 'TokenLookupTests.swift')
    packages = ['OathAnkr', 'OathDatabase', 'OathBitcoin', 'OathDiagnostics', 'OathTokenImages']
    deps = ', '.join('.package(path: %s)' % json.dumps(str(root / 'Packages' / p)) for p in packages)
    names = ', '.join(json.dumps(p) for p in packages)
    (work / 'Package.swift').write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "TokenLookup", platforms: [.macOS("15.5")], dependencies: [%s],
 targets: [.target(name: "TokenLookup", dependencies: [%s]),
 .testTarget(name: "TokenLookupTests", dependencies: ["TokenLookup", "OathDiagnostics"])],
 swiftLanguageModes: [.v6])
''' % (deps, names))
    raise SystemExit(subprocess.run(['swift', 'test', '--package-path', str(work), '--scratch-path',
        '/tmp/oath-token-lookup-host'], env=env, timeout=600).returncode)

#!/usr/bin/env python3
"""Host regression checks for production EVM token search/RPC handling.

The iOS-only WalletCore keccak adapter is replaced by OathAnkr's equivalent.
Base58 paths are deliberately unsupported here; this is an EVM-only check.
Optional --live reads real public contracts using bundled RPC configuration.
"""
import argparse, json, os, plistlib, shutil, subprocess, tempfile
from pathlib import Path
parser = argparse.ArgumentParser()
parser.add_argument('--live', action='store_true')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
env = os.environ.copy()
if args.live:
    with (root / 'OathApp/Private/TokenRPC.plist').open('rb') as file:
        env['OATH_TOKEN_LOOKUP_LIVE_KEY'] = plistlib.load(file)['AnkrAPIKey']
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
enum Base58 {
 static func decode(string: String) -> Data? { fatalError("Base58 is outside this EVM host check") }
 static func decodeNoCheck(string: String) -> Data? { fatalError("Base58 is outside this EVM host check") }
 static func encodeNoCheck(data: Data) -> String { fatalError("Base58 is outside this EVM host check") }
}
''')
    shutil.copyfile(root / 'Tools/TokenLookupValidation/TokenLookupTests.swift', tests / 'TokenLookupTests.swift')
    packages = ['OathAnkr', 'OathDatabase', 'OathBitcoin', 'OathDiagnostics']
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
        '/tmp/oath-token-lookup-host'], env=env, timeout=240).returncode)

#!/usr/bin/env python3
"""Compile the contact models against real SQLite and diagnostics on the host.

Exercises the production NEAR and UTXO address validator branches. WalletCore's
iOS-only branches deliberately trap if called; UIKit haptics and the app's
database locator are replaced by host collectors. No simulator or network.
"""
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='oath-contact-validation-') as temporary:
    work = Path(temporary)
    sources, tests = work / 'Sources/ContactValidation', work / 'Tests/ContactValidationTests'
    sources.mkdir(parents=True)
    tests.mkdir(parents=True)
    for name in ['Contacts/OathContactsModel.swift', 'Import/OathImportCatalog.swift', 'Localization/OathStringKey.swift']:
        shutil.copyfile(root / 'OathAtmosphere' / name, sources / Path(name).name)
    validator = (root / 'OathAtmosphere/Contacts/OathContactAddressValidator.swift').read_text()
    (sources / 'OathContactAddressValidator.swift').write_text(validator.replace('import WalletCore\n', ''))
    (sources / 'HostSupport.swift').write_text('''import Foundation
import OathDatabase
enum CoinType { case ethereum }
struct AnyAddress {
 static func isValid(string: String, coin: CoinType) -> Bool { fatalError("WalletCore branch outside host coverage") }
 init?(string: String, coin: CoinType) { fatalError("WalletCore branch outside host coverage") }
 var description: String { fatalError("WalletCore branch outside host coverage") }
}
extension OathImportChain { var walletCoin: CoinType { fatalError("WalletCore branch outside host coverage") } }
@MainActor final class OathDataEnvironment {
 static let shared = OathDataEnvironment()
 var value: OathDatabase!
 func database() async throws -> OathDatabase { value }
}
@MainActor final class OathHaptics {
 enum Event: Equatable { case success, error }
 static let shared = OathHaptics()
 var events: [Event] = []
 func play(_ event: Event) { events.append(event) }
}
''')
    shutil.copyfile(root / 'Tools/ContactValidation/ContactValidationTests.swift', tests / 'ContactValidationTests.swift')
    packages = ['OathDatabase', 'OathDiagnostics', 'OathBitcoin']
    deps = ', '.join('.package(path: %s)' % json.dumps(str(root / 'Packages' / p)) for p in packages)
    names = ', '.join(json.dumps(p) for p in packages)
    (work / 'Package.swift').write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "ContactValidation", platforms: [.macOS("15.5")], dependencies: [%s],
 targets: [.target(name: "ContactValidation", dependencies: [%s]),
 .testTarget(name: "ContactValidationTests", dependencies: ["ContactValidation", "OathDatabase", "OathDiagnostics"])],
 swiftLanguageModes: [.v6])
''' % (deps, names))
    raise SystemExit(subprocess.run(['swift', 'test', '--package-path', str(work), '--scratch-path',
        '/tmp/oath-contact-validation-host'], timeout=240).returncode)

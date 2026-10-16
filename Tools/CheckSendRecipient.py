#!/usr/bin/env python3
"""Host tests of real recipient rules/model/SQLite. No app, device or network.

WalletCore is iOS-only: syntax validation uses the real shared scanner decoder.
All self-recipient logic, account decoding and navigation guards are production.
"""
from pathlib import Path
import json
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="oath-recipient-") as temporary:
    work = Path(temporary)
    source = work / "Sources/RecipientChecks"
    source.mkdir(parents=True)
    for file in ["Import/OathImportCatalog.swift", "Import/OathMnemonicValidator.swift",
                 "Scanner/OathScanAddress.swift", "Scanner/OathScanPayload.swift",
                 "Send/OathSendRecipientRules.swift", "Send/OathSendModel.swift", "Send/OathSendAmount.swift",
                 "Localization/OathStringKey.swift"]:
        shutil.copyfile(root / "OathAtmosphere" / file, source / Path(file).name)
    tracking = (root / "OathAtmosphere/Send/OathSendStatusTracking.swift").read_text()
    registry = tracking[tracking.index("enum OathTrackedSendChain"):tracking.index("    static func check(")] + "}\n"
    (source / "HostEnvironment.swift").write_text('''import Foundation
import OathDatabase
actor OathDataEnvironment {
    static let shared = OathDataEnvironment()
    var store: OathDatabase?
    func set(_ db: OathDatabase) { store = db }
    func database() throws -> OathDatabase {
        guard let store else { throw CocoaError(.fileNoSuchFile) }; return store
    }
}
enum OathContactAddressValidator {
    static func isValid(_ input: String, networkID: String) -> Bool {
        guard let chain = OathImportChain(rawValue: networkID) else { return false }
        return OathScanAddress.decode(input, chain: chain) != nil
    }
}
''' + registry)
    shutil.copyfile(root / "Tools/CheckSendRecipient.swift", source / "CheckSendRecipient.swift")
    packages = ["OathAnkr", "OathBitcoin", "OathDatabase", "OathDiagnostics"]
    deps = ", ".join('.package(path: %s)' % json.dumps(str(root / "Packages" / p)) for p in packages)
    (work / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "RecipientChecks", platforms: [.macOS("15.5")],
    dependencies: [%s],
    targets: [.executableTarget(name: "RecipientChecks", dependencies: [%s])],
    swiftLanguageModes: [.v6])
''' % (deps, ", ".join(json.dumps(p) for p in packages)))
    subprocess.run(["swift", "run", "--package-path", str(work), "--scratch-path", "/tmp/oath-recipient-host-build",
                    "RecipientChecks"], check=True)

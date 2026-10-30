#!/usr/bin/env python3
"""Validate production Receive account/token routing and QR output on macOS."""
from pathlib import Path
import json
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="oath-receive-selection-") as temporary:
    work = Path(temporary)
    source = work / "Sources/ReceiveChecks"
    source.mkdir(parents=True)
    for file in ["Home/OathReceiveAsset.swift", "Home/OathReceiveQRCode.swift", "Import/OathImportCatalog.swift"]:
        shutil.copyfile(root / "OathAtmosphere" / file, source / Path(file).name)
    # Compile the real value type without the unrelated iOS-only WalletCore engine.
    engine = (root / "OathAtmosphere/Wallet/OathWalletEngine.swift").read_text()
    address = engine[engine.index("struct OathWalletAddress:"):engine.index("struct OathWalletProfile:")]
    ticker = engine[engine.index("    var ticker: String {", engine.index("extension OathImportChain")):]
    (source / "OathWalletAddress.swift").write_text("import Foundation\n" + address + "\nextension OathImportChain {\n" + ticker)
    shutil.copyfile(root / "Tools/CheckReceiveSelection.swift", source / "CheckReceiveSelection.swift")
    shutil.copyfile(root / "Tools/CheckReceivePreparation.swift", source / "CheckReceivePreparation.swift")
    (work / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "ReceiveChecks", platforms: [.macOS("15.5")],
    dependencies: [.package(path: %s), .package(path: %s)],
    targets: [.executableTarget(name: "ReceiveChecks", dependencies: ["OathDatabase", "OathBitcoin"])],
    swiftLanguageModes: [.v6])
''' % (json.dumps(str(root / "Packages/OathDatabase")), json.dumps(str(root / "Packages/OathBitcoin"))))
    subprocess.run(["swift", "run", "--package-path", str(work), "--scratch-path", "/tmp/oath-receive-selection-host-build",
                    "--build-system", "native", "ReceiveChecks", *sys.argv[1:]], check=True)

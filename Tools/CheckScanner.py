#!/usr/bin/env python3
"""Host-only production scanner checks. Public vectors; no app, camera or wallet access."""
from pathlib import Path
import json
import shutil
import subprocess
import tempfile
import sys

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="oath-scanner-") as temporary:
    work = Path(temporary)
    source = work / "Sources/ScannerChecks"
    source.mkdir(parents=True)
    for file in ["Import/OathImportCatalog.swift", "Import/OathMnemonicValidator.swift",
                 "Scanner/OathScanAddress.swift", "Scanner/OathScanImage.swift", "Scanner/OathScanPayload.swift",
                 "Scanner/OathScanRecognizer.swift", "Scanner/OathScannerCaptureState.swift",
                 "Scanner/OathWalletConnectPolicy.swift", "Scanner/OathWalletConnectConnections.swift", "Scanner/OathWalletConnectMessage.swift",
                 "Scanner/OathWalletLink.swift", "Home/OathReceiveQRCode.swift"]:
        shutil.copyfile(root / "OathAtmosphere" / file, source / Path(file).name)
    # Copy the real network registry; provider credentials/synchronizers are not needed.
    registry = (root / "OathAtmosphere/Tokens/OathTokenNetwork.swift").read_text()
    (source / "Networks.swift").write_text("import Foundation\n" + registry[registry.index("struct OathTokenNetwork"):registry.index("struct OathTokenDefinition")])
    check = "CheckWalletConnectHandoff.swift" if "--handoff" in sys.argv else "CheckPaymentQRLive.swift" if "--payment-live" in sys.argv else "CheckWalletConnectConnections.swift" if "--connections" in sys.argv else "CheckScannerPerformance.swift" if "--performance" in sys.argv else "CheckWalletLinks.swift" if "--links" in sys.argv else "CheckScanner.swift"
    check_source = (root / "Tools" / check).read_text()
    if "--handoff" in sys.argv:
        service = (root / "OathAtmosphere/Scanner/OathWalletConnectService.swift").read_text()
        methods = service[service.index("    private func canHandoffCompletion("):service.index("    @discardableResult func presentationDidOpen(")]
        check_source = check_source.replace("    // PRODUCTION_HANDOFF_METHODS", methods)
    (source / "CheckScanner.swift").write_text(check_source)
    (work / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "ScannerChecks", platforms: [.macOS("15.5")],
    dependencies: [.package(path: %s), .package(path: %s), .package(path: %s), .package(path: %s), .package(path: %s)],
    targets: [.executableTarget(name: "ScannerChecks", dependencies: ["OathAezeed", "OathAnkr", "OathBitcoin", "OathDiagnostics", "OathDatabase"])],
    swiftLanguageModes: [.v6])
''' % (json.dumps(str(root / "Packages/OathAezeed")), json.dumps(str(root / "Packages/OathAnkr")), json.dumps(str(root / "Packages/OathBitcoin")), json.dumps(str(root / "Packages/OathDiagnostics")), json.dumps(str(root / "Packages/OathDatabase"))))
    subprocess.run(["swift", "run", "--package-path", str(work), "--scratch-path", "/tmp/oath-scanner-host-build",
                    "--build-system", "native", "ScannerChecks", str(root)], check=True)

#!/usr/bin/env python3
"""Run the complete amount harness against production implementations on macOS.

No simulator, wallet accounts, RPC calls, or signing are used. SwiftPM may fetch
build dependencies on the first run.
"""
from pathlib import Path
import json
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="oath-send-amount-") as temporary:
    work = Path(temporary)
    source = work / "Sources/AmountChecks"
    source.mkdir(parents=True)
    for file in ["Send/OathSendAmount.swift", "Send/OathSendRecipientRules.swift",
                 "Home/OathAssetAmountFormat.swift", "Import/OathImportCatalog.swift",
                 "Scanner/OathScanAddress.swift", "Localization/OathStringKey.swift"]:
        shutil.copyfile(root / "OathAtmosphere" / file, source / Path(file).name)
    shutil.copyfile(root / "Tools/CheckSendAmount.swift", source / "CheckSendAmount.swift")
    packages = ["OathAnkr", "OathBitcoin"]
    dependencies = ", ".join('.package(path: %s)' % json.dumps(str(root / "Packages" / p)) for p in packages)
    (work / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "AmountChecks", platforms: [.macOS("15.5")],
    dependencies: [%s],
    targets: [.executableTarget(name: "AmountChecks", dependencies: [%s])],
    swiftLanguageModes: [.v6])
''' % (dependencies, ", ".join(json.dumps(p) for p in packages)))
    subprocess.run(["swift", "run", "--build-system", "native", "--package-path", str(work),
                    "--scratch-path", "/tmp/oath-send-amount-host-build", "--jobs", "4", "AmountChecks"], check=True)

#!/usr/bin/env python3
"""Host-only checks of production Home presentation. Synthetic balances only."""
from pathlib import Path
import json
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="oath-home-portfolio-") as temporary:
    work = Path(temporary)
    source = work / "Sources/HomeChecks"
    source.mkdir(parents=True)
    for file in ["Home/OathHomePortfolioModel.swift", "Home/OathAssetAmountFormat.swift",
                 "Import/OathImportCatalog.swift"]:
        shutil.copyfile(root / "OathAtmosphere" / file, source / Path(file).name)
    shutil.copyfile(root / "Tools/CheckHomePortfolio.swift", source / "CheckHomePortfolio.swift")
    (work / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "HomeChecks", platforms: [.macOS("15.5")],
    dependencies: [.package(path: %s), .package(path: %s)],
    targets: [.executableTarget(name: "HomeChecks", dependencies: ["OathDatabase", "OathDiagnostics"])],
    swiftLanguageModes: [.v6])
''' % (json.dumps(str(root / "Packages/OathDatabase")), json.dumps(str(root / "Packages/OathDiagnostics"))))
    subprocess.run(["swift", "run", "--package-path", str(work), "--scratch-path", "/tmp/oath-home-portfolio-host-build",
                    "--build-system", "native", "HomeChecks"], check=True)

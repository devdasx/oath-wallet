#!/usr/bin/env python3
"""Exercise the production history model against isolated SQLite on the Mac."""
from pathlib import Path
import json
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="oath-history-presentation-") as temporary:
    work = Path(temporary)
    source = work / "Sources/HistoryChecks"
    source.mkdir(parents=True)
    model = (root / "OathAtmosphere/Assets/OathAssetDetailModel.swift").read_text()
    model = model[model.index("@MainActor @Observable final class OathChainActivityModel"):]
    snapshot = (root / "OathAtmosphere/Home/OathHomePortfolioModel.swift").read_text()
    snapshot = snapshot[snapshot.index("struct OathHomeHistorySnapshot {"):]
    snapshot = snapshot[:snapshot.index("\n}") + 2]
    (source / "HistoryModel.swift").write_text(
        "import Foundation\nimport Observation\nimport OathDatabase\nimport OathDiagnostics\n" + snapshot + "\n" + model)
    shutil.copyfile(root / "Tools/CheckHistoryPresentation.swift", source / "CheckHistoryPresentation.swift")
    (work / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "HistoryChecks", platforms: [.macOS("15.5")],
    dependencies: [.package(path: %s), .package(path: %s)],
    targets: [.executableTarget(name: "HistoryChecks", dependencies: ["OathDatabase", "OathDiagnostics"])],
    swiftLanguageModes: [.v6])
''' % (json.dumps(str(root / "Packages/OathDatabase")), json.dumps(str(root / "Packages/OathDiagnostics"))))
    subprocess.run(["swift", "run", "--package-path", str(work), "--scratch-path", "/tmp/oath-history-presentation-host",
                    "--build-system", "native", "HistoryChecks"], check=True)

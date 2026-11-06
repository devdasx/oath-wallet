#!/usr/bin/env python3
"""Render the production row on macOS with its real package dependencies.

Uses synthetic content and host font/artwork bridges; this is not an iOS test.
"""
from pathlib import Path
import json
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="oath-row-checks-") as temporary:
    work = Path(temporary)
    sources = work / "Sources/RowChecks"
    sources.mkdir(parents=True)
    for name in ["OathAtmosphere/Shared/OathRefinedListRow.swift",
                 "OathAtmosphere/Home/OathAssetAmountFormat.swift",
                 "Tools/CheckRefinedRows.swift"]:
        shutil.copyfile(root / name, sources / Path(name).name)
    (work / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "RowChecks", platforms: [.macOS("15.5")],
    dependencies: [.package(path: %s)],
    targets: [.executableTarget(name: "RowChecks", dependencies: ["OathTokenImages"])],
    swiftLanguageModes: [.v6])
''' % json.dumps(str(root / "Packages/OathTokenImages")))
    subprocess.run(["swift", "run", "--package-path", str(work),
                    "--scratch-path", "/tmp/oath-refined-row-host-build",
                    "--build-system", "native", "--jobs", "4", "RowChecks"], check=True)

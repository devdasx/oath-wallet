#!/usr/bin/env python3
"""Check production Receive examples, bundled artwork and QR output on macOS."""
from pathlib import Path
import json
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="oath-receive-experience-") as temporary:
    work = Path(temporary)
    source = work / "Sources/ReceiveExperienceChecks"
    source.mkdir(parents=True)
    for file in ["Home/OathReceiveNetworkGuide.swift", "Home/OathReceiveQRCode.swift",
                 "Import/OathImportCatalog.swift", "Localization/OathStringKey.swift"]:
        shutil.copyfile(root / "OathAtmosphere" / file, source / Path(file).name)
    shutil.copyfile(root / "Tools/CheckReceiveExperience.swift", source / "CheckReceiveExperience.swift")
    (work / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "ReceiveExperienceChecks", platforms: [.macOS("15.5")],
    dependencies: [.package(path: %s), .package(path: %s), .package(path: %s)],
    targets: [.executableTarget(name: "ReceiveExperienceChecks", dependencies: ["OathDatabase", "OathDiagnostics", "OathAnkr"])],
    swiftLanguageModes: [.v6])
''' % (json.dumps(str(root / "Packages/OathDatabase")), json.dumps(str(root / "Packages/OathDiagnostics")), json.dumps(str(root / "Packages/OathAnkr"))))
    subprocess.run(["swift", "run", "--package-path", str(work), "--scratch-path", "/tmp/oath-receive-selection-host-build",
                    "--build-system", "native", "ReceiveExperienceChecks"], cwd=root, check=True)

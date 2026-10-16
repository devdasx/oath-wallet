#!/usr/bin/env python3
"""Run the production refresh action boundary on the host, without UIKit or a simulator."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="oath-refresh-actions-") as temporary:
    work = Path(temporary)
    source = work / "Sources/RefreshActionCore"
    source.mkdir(parents=True)
    shutil.copy(root / "Packages/OathNativeRefresh/Sources/OathNativeRefresh/RefreshAction.swift", source)
    shutil.copytree(root / "Tools/NativeRefreshValidation", work / "Tests/RefreshActionTests",
                    ignore=shutil.ignore_patterns("._*"))
    dependency = json.dumps(str(root / "Packages/OathDiagnostics"))
    (work / "Package.swift").write_text(f'''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "RefreshActionValidation", platforms: [.macOS(.v14)],
    dependencies: [.package(path: {dependency})],
    targets: [.target(name: "RefreshActionCore", dependencies: ["OathDiagnostics"]),
              .testTarget(name: "RefreshActionTests", dependencies: ["RefreshActionCore", "OathDiagnostics"])],
    swiftLanguageModes: [.v6])
''')
    result = subprocess.run(["swift", "test", "--package-path", str(work),
                             "--scratch-path", "/tmp/oath-refresh-action-host"], timeout=120)
    raise SystemExit(result.returncode)

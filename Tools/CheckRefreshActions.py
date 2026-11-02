#!/usr/bin/env python3
"""Run the production refresh action boundary on the host, without UIKit or a simulator."""
import json
import re
import sys
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="oath-refresh-actions-") as temporary:
    work = Path(temporary)
    source = work / "Sources/RefreshActionCore"
    source.mkdir(parents=True)
    for name in ["RefreshAction.swift", "BackgroundRefresh.swift", "RefreshCycle.swift"]:
        shutil.copy(root / "Packages/OathNativeRefresh/Sources/OathNativeRefresh" / name, source)
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
    # OathDiagnostics deliberately configures its process-wide outbox once.
    # Give each suite its own process/transport, as the app does at launch.
    for suite in ["RefreshActionTests.BackgroundRefreshTests", "RefreshActionTests.RefreshActionTests"]:
        result = subprocess.run(["swift", "test", "--package-path", str(work),
                                 "--scratch-path", "/tmp/oath-refresh-action-host",
                                 "--filter", suite], timeout=120, capture_output=True, text=True)
        output = result.stdout + result.stderr
        sys.stdout.write(output)
        if result.returncode:
            raise SystemExit(result.returncode)
        class_name = suite.rsplit(".", 1)[1]
        completed = re.findall(r"^Test Case .+\." + re.escape(class_name) + r" test\w+\].+passed \(", output, re.MULTILINE)
        if not completed:
            raise SystemExit("No passing test case executed for " + suite)

#!/usr/bin/env python3
"""Render production refresh and Settings symbols on the host; no simulator."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="oath-rtl-indicators-") as directory:
    work = Path(directory)
    source = (root / "OathAtmosphere/Home/OathSettingsStyle.swift").read_text()
    settings = source.split("enum OathWalletCreationOptions", 1)[0].replace("import OathTokenImages", "")
    (work / "SettingsRows.swift").write_text(settings)
    refresh = root / "Packages/OathNativeRefresh/Sources/OathNativeRefresh"
    sources = [refresh / name for name in ["BrandedRefreshIndicator.swift", "RefreshIndicatorModel.swift",
                                          "RefreshCycle.swift", "OathRefreshMark.swift"]]
    sources += [work / "SettingsRows.swift", root / "Tools/NativeRefreshPlacement/SettingsSupport.swift",
                root / "Tools/CheckRTLIndicators.swift"]
    executable = work / "RTLIndicators"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
                    "-D", "OATH_SETTINGS_FIXTURE", *map(str, sources), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=60)

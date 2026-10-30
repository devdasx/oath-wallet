#!/usr/bin/env python3
"""Opt-in UIKit placement/gesture regression using an isolated synthetic app."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid


def run(*args):
    return subprocess.run(args, check=True, text=True, capture_output=True, timeout=180).stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator-check", action="store_true")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--only-testing", action="append", default=[])
    parser.add_argument("--device-type", default="com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max")
    parser.add_argument("--unmodified-baseline", action="store_true", help="Opt in to the known failing Apple ScrollView reproducer")
    args = parser.parse_args()
    if not args.simulator_check:
        parser.error("State the unresolved runtime concern first, then opt in with --simulator-check.")
    root = Path(__file__).resolve().parents[1]
    args.output.mkdir(parents=True, exist_ok=True)
    device = None
    with tempfile.TemporaryDirectory(prefix="oath-refresh-placement-") as temporary:
        work = Path(temporary)
        shutil.copytree(root / "Tools/NativeRefreshPlacement", work / "Fixture",
                        ignore=shutil.ignore_patterns("._*"))
        spec = {
            "name": "RefreshPlacement", "options": {"deploymentTarget": {"iOS": "26.0"}},
            "packages": {"OathNativeRefresh": {"path": str(root / "Packages/OathNativeRefresh")}},
            "settings": {"base": {"CODE_SIGNING_ALLOWED": "NO", "SWIFT_VERSION": "6.0",
                                   "GENERATE_INFOPLIST_FILE": "YES"}},
            "targets": {
                "RefreshPlacement": {
                    "type": "application", "platform": "iOS", "sources": ["Fixture/Probe.swift", str(root / "OathAtmosphere/Home/OathHomeBodySurface.swift"),
                        str(root / "OathAtmosphere/OathEmptyStateLayout.swift")],
                    "dependencies": [{"package": "OathNativeRefresh"}],
                    "settings": {"base": {"PRODUCT_BUNDLE_IDENTIFIER": "org.oathwallet.refresh-placement",
                        "INFOPLIST_KEY_UILaunchScreen_Generation": "YES"}}},
                "PlacementUITests": {
                    "type": "bundle.ui-testing", "platform": "iOS", "sources": ["Fixture/PlacementUITests.swift"],
                    "dependencies": [{"target": "RefreshPlacement"}],
                    "settings": {"base": {"PRODUCT_BUNDLE_IDENTIFIER": "org.oathwallet.refresh-placement.tests"}}}
            },
            "schemes": {"RefreshPlacement": {
                "build": {"targets": {"RefreshPlacement": "all", "PlacementUITests": ["test"]}},
                "test": {"targets": ["PlacementUITests"], "environmentVariables": {"OATH_REFRESH_BASELINE": "1" if args.unmodified_baseline else "0"}}}}
        }
        (work / "project.yml").write_text(json.dumps(spec))
        run("xcodegen", "generate", "--spec", str(work / "project.yml"))
        try:
            device = run("xcrun", "simctl", "create", "Oath Refresh Placement " + uuid.uuid4().hex[:8],
                         args.device_type,
                         "com.apple.CoreSimulator.SimRuntime.iOS-27-0")
            with (args.output / "test.log").open("w") as log:
                result = subprocess.run([
                    "xcodebuild", "-project", str(work / "RefreshPlacement.xcodeproj"),
                    "-scheme", "RefreshPlacement", "-destination", "platform=iOS Simulator,id=" + device,
                    "-derivedDataPath", str(work / "build"), "-parallel-testing-enabled", "NO",
                    "-resultBundlePath", str(args.output / "Placement.xcresult"),
                    *["-only-testing:" + test for test in args.only_testing], "test"
                ], stdout=log, stderr=subprocess.STDOUT, timeout=600)
            result.check_returncode()
            print("PASS: " + (", ".join(args.only_testing) if args.only_testing else "native refresh placement and interaction regression suite"))
        finally:
            if device:
                subprocess.run(["xcrun", "simctl", "shutdown", device], capture_output=True, timeout=60)
                subprocess.run(["xcrun", "simctl", "delete", device], check=True, capture_output=True, timeout=60)


if __name__ == "__main__":
    main()

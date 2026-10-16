#!/usr/bin/env python3
"""Opt-in, isolated UIKit regression. Never opens Oath or any wallet data."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import uuid


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, capture_output=True,
                          timeout=kwargs.pop("timeout", 120), **kwargs).stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator-check", action="store_true",
                        help="Explicitly run after identifying a runtime uncertainty under AGENTS.md")
    parser.add_argument("--runtime", help="Installed iOS Simulator runtime identifier")
    parser.add_argument("--device-type", default="com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not args.simulator_check:
        parser.error("This check launches its own simulator; pass --simulator-check only when justified.")
    root = Path(__file__).resolve().parents[1]
    runtimes = json.loads(run("xcrun", "simctl", "list", "runtimes", "-j"))["runtimes"]
    available = [r for r in runtimes if r.get("isAvailable") and r["name"].startswith("iOS")]
    available.sort(key=lambda r: tuple(map(int, r["version"].split("."))))
    runtime = args.runtime or available[-1]["identifier"]
    device = None
    results = {}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="oath-home-scroll-") as temporary:
        work = Path(temporary)
        shutil.copy(root / "Tools/Fixtures/HomeScrollProbe.swift", work / "Probe.swift")
        # JSON is also valid YAML and avoids quoting local paths incorrectly.
        spec = {
            "name": "OathScrollProbe",
            "options": {"deploymentTarget": {"iOS": "17.0"}},
            "packages": {"OathNativeRefresh": {"path": str(root / "Packages/OathNativeRefresh")}},
            "targets": {"OathScrollProbe": {
                "type": "application", "platform": "iOS",
                "sources": ["Probe.swift", str(root / "OathAtmosphere/Home/OathHomeBodySurface.swift"),
                            str(root / "OathAtmosphere/OathEmptyStateLayout.swift")],
                "dependencies": [{"package": "OathNativeRefresh"}],
                "settings": {"base": {"PRODUCT_BUNDLE_IDENTIFIER": "org.oathwallet.scroll-probe",
                    "GENERATE_INFOPLIST_FILE": "YES", "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
                    "CODE_SIGNING_ALLOWED": "NO", "SWIFT_VERSION": "6.0"}}
            }}
        }
        (work / "project.yml").write_text(json.dumps(spec))
        run("xcodegen", "generate", "--spec", str(work / "project.yml"))
        build = subprocess.run([
            "xcodebuild", "-project", str(work / "OathScrollProbe.xcodeproj"),
            "-scheme", "OathScrollProbe", "-destination", "generic/platform=iOS Simulator",
            "-derivedDataPath", str(work / "build"), "CODE_SIGNING_ALLOWED=NO", "build"
        ], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=600)
        args.output.with_suffix(".build.log").write_text(build.stdout)
        build.check_returncode()
        try:
            device = run("xcrun", "simctl", "create", "Oath Home Probe " + uuid.uuid4().hex[:8],
                         args.device_type, runtime)
            run("xcrun", "simctl", "boot", device)
            run("xcrun", "simctl", "bootstatus", device, "-b", timeout=180)
            run("xcrun", "simctl", "install", device,
                str(work / "build/Build/Products/Debug-iphonesimulator/OathScrollProbe.app"))
            for mode in ("system", "branded"):
                run("xcrun", "simctl", "launch", device, "org.oathwallet.scroll-probe",
                    *( ["--branded"] if mode == "branded" else [] ))
                container = Path(run("xcrun", "simctl", "get_app_container", device,
                                     "org.oathwallet.scroll-probe", "data"))
                result = container / "Documents/hosted.json"
                deadline = time.monotonic() + 30
                while not result.exists() and time.monotonic() < deadline:
                    time.sleep(0.25)
                metrics = json.loads(result.read_text())
                results[mode] = metrics
                assert 0 < metrics["initialRowBodies"] < 50, metrics
                assert metrics["evaluations"] < 500, metrics
                assert metrics["updatedRowBodies"] > metrics["initialRowBodies"], metrics
                assert metrics["refreshAttached"] and metrics["refreshEnded"], metrics
                assert metrics["refreshes"] == 1 and metrics["scrollCallbacks"] > 0, metrics
                run("xcrun", "simctl", "terminate", device, "org.oathwallet.scroll-probe")
                result.unlink()
            args.output.write_text(json.dumps(results, indent=2) + "\n")
            print("PASS: lazy rows, native scroll callbacks, system and branded refresh completion")
        finally:
            if device:
                # Only the UUID created above; never touch a user's other simulators.
                subprocess.run(["xcrun", "simctl", "shutdown", device], capture_output=True, timeout=60)
                subprocess.run(["xcrun", "simctl", "delete", device], check=True, capture_output=True, timeout=60)


if __name__ == "__main__":
    main()

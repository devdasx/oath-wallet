#!/usr/bin/env python3
"""Build only. Never creates, launches, installs on, or erases a simulator/device."""
import argparse
import pathlib
import platform
import plistlib
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--lifecycle", required=True, choices=("swiftui", "uikit"))
parser.add_argument("--output", required=True, type=pathlib.Path)
args = parser.parse_args()
output = args.output.resolve()
if output.exists():
    parser.error("Use a new output directory; existing files are never replaced.")
output.mkdir(parents=True)

manifest = {"UIApplicationSupportsMultipleScenes": False}
if args.lifecycle == "uikit":
    manifest["UISceneConfigurations"] = {
        "UIWindowSceneSessionRoleApplication": [{
            "UISceneConfigurationName": "Main",
            "UISceneDelegateClassName": "OathAtmosphere.OathSceneDelegate",
        }]
    }
info = {
    "CFBundleExecutable": "OathAtmosphere",
    "CFBundleIdentifier": "com.aperture.wallet",
    "CFBundleName": "OathAtmosphere",
    "CFBundleDisplayName": "Oath Launch Fixture",
    "CFBundlePackageType": "APPL",
    "CFBundleVersion": "1",
    "CFBundleShortVersionString": "1.0",
    "MinimumOSVersion": "17.0",
    "LSRequiresIPhoneOS": True,
    "UIDeviceFamily": [1, 2],
    "UILaunchScreen": {},
    "UIApplicationSceneManifest": manifest,
}
(output / "Info.plist").write_bytes(plistlib.dumps(info))
sdk = subprocess.check_output(
    ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
command = [
    "xcrun", "--sdk", "iphonesimulator", "swiftc", "-parse-as-library",
    "-target", f"{platform.machine()}-apple-ios17.0-simulator", "-sdk", sdk,
    "-module-name", "OathAtmosphere",
]
if args.lifecycle == "swiftui":
    command += ["-D", "LEGACY_SWIFTUI"]
command += [str(pathlib.Path(__file__).parent / "LaunchFixtures/LegacyApp.swift"),
            "-o", str(output / "OathAtmosphere")]
subprocess.run(command, check=True)
subprocess.run(["codesign", "--force", "--sign", "-", str(output)], check=True)
print(f"Built {args.lifecycle} launch fixture: {output}")

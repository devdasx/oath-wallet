#!/usr/bin/env python3
"""Fetch checksum-pinned debug symbols for the reviewed Core source build.

Run once on each build machine, or pass --downloads for a previously downloaded
release directory. Only public review-release assets are accessed. The Xcode build
phase stays offline; this cache is ignored by Git and never bundled in the app.
"""
import argparse
import hashlib
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parent.parent
VERSION = "4.8.4-oath-review1"
RELEASE_BASE = "https://github.com/devdasx/oath-wallet-security-review/releases/download/review-4.1.15-build100-progress19"
ASSETS = {
    "WalletCore": (
        "225c99906b3ba08474e4453ba05e9d6f7ed9a332603836bcac159009cf963dc1",
        "08FFD60A-E21D-354B-AD70-C02731D58624",
    ),
    "WalletCoreSwiftProtobuf": (
        "004153aa53ab67321016e2372a806972405ea3e3c08e902a0dfa70046b2074f7",
        "2C12FA7A-E54F-3CFB-9BA1-3F11EA73A18D",
    ),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--downloads", type=Path)
    args = parser.parse_args()
    target = ROOT / "Packages/WalletCore/.build/symbols/ios-arm64"
    with tempfile.TemporaryDirectory(prefix="oath-release-symbols-") as scratch:
        scratch = Path(scratch)
        prepared = []
        for name, (checksum, expected_uuid) in ASSETS.items():
            filename = f"{name}.xcframework.dSYM.zip"
            archive = args.downloads / filename if args.downloads else scratch / filename
            if not args.downloads:
                url = f"{RELEASE_BASE}/{filename}"
                with urllib.request.urlopen(url, timeout=60) as response, archive.open("wb") as output:
                    shutil.copyfileobj(response, output)
            with archive.open("rb") as data:
                digest = hashlib.sha256()
                while chunk := data.read(1024 * 1024):
                    digest.update(chunk)
                actual = digest.hexdigest()
            if actual != checksum:
                raise ValueError(f"Checksum mismatch for {filename}")
            prefix = f"{name}.dSYMs/{name}.framework.ios-arm64.dSYM/"
            dsym = scratch / f"{name}.framework.dSYM"
            with zipfile.ZipFile(archive) as bundle:
                for entry in bundle.infolist():
                    if not entry.filename.startswith(prefix) or entry.is_dir():
                        continue
                    relative = PurePosixPath(entry.filename[len(prefix):])
                    if relative.is_absolute() or ".." in relative.parts:
                        raise ValueError("Invalid published symbol path")
                    output = dsym / relative
                    output.parent.mkdir(parents=True, exist_ok=True)
                    with bundle.open(entry) as source, output.open("wb") as destination:
                        shutil.copyfileobj(source, destination)
            dwarf = dsym / "Contents/Resources/DWARF" / name
            uuids = subprocess.check_output(["xcrun", "dwarfdump", "--uuid", str(dwarf)], text=True)
            if re.findall(r"UUID: ([A-F0-9-]+) \(([^)]+)\)", uuids) != [(expected_uuid, "arm64")]:
                raise ValueError(f"Unexpected device UUID in {name} symbols")
            prepared.append((name, dsym))
        # Install only after both public downloads have been fully verified.
        target.mkdir(parents=True, exist_ok=True)
        for name, dsym in prepared:
            destination = target / dsym.name
            if destination.exists():
                shutil.rmtree(destination)
            shutil.copytree(dsym, destination)
            print(f"Prepared verified {name} {VERSION} device symbols.")


if __name__ == "__main__":
    main()

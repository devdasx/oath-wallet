#!/usr/bin/env python3
"""Fetch authentic, checksum-pinned WalletCore 4.8.4 device debug symbols.

Run once on each build machine, or pass --downloads for a previously downloaded
release directory. Only public upstream assets are accessed. The Xcode build
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
VERSION = "4.8.4"
ASSETS = {
    "WalletCore": (
        "8b1fca956d1150b7a0386694cdf1ac6a7800c202689b576df70a95abe2b57279",
        "4C0AD6A9-0446-35B1-9BC1-4A75400B2C5A",
    ),
    "WalletCoreSwiftProtobuf": (
        "64299469ac01844d9286e9e503186d13260173c8fc45d02d17132bd1e1fcddfe",
        "0941ECD2-9EC2-391C-9DB4-B155227B4DDF",
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
                url = f"https://github.com/trustwallet/wallet-core/releases/download/{VERSION}/{filename}"
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
                        raise ValueError("Invalid upstream symbol path")
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
            print(f"Prepared authentic {name} {VERSION} device symbols.")


if __name__ == "__main__":
    main()

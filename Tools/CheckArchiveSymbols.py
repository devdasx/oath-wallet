"""Verify the two distributed Wallet Core frameworks and their archived dSYMs."""
import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess


def verify(archive):
    with (archive / "Info.plist").open("rb") as stream:
        application = plistlib.load(stream)["ApplicationProperties"]["ApplicationPath"]
    frameworks = archive / "Products" / application / "Frameworks"
    provenance = Path(__file__).resolve().parents[1] / "Packages/WalletCore/provenance.json"
    artifacts = json.loads(provenance.read_text())["artifacts"]
    for name in ("WalletCore", "WalletCoreSwiftProtobuf"):
        expected = [(artifacts[name]["device_uuid"], "arm64")]
        binary = frameworks / (name + ".framework") / name
        symbols = archive / "dSYMs" / (name + ".framework.dSYM") / "Contents/Resources/DWARF" / name
        for item in (binary, symbols):
            result = subprocess.check_output(["xcrun", "dwarfdump", "--uuid", str(item)], text=True)
            if re.findall(r"UUID: ([A-F0-9-]+) \(([^)]+)\)", result) != expected:
                raise ValueError(f"{name} UUID does not match the device artifact in provenance.json")
        print(f"Verified {name} device binary and debug symbols.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    verify(parser.parse_args().archive)

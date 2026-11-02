"""Reproduce the distribution XCFramework from the checksum-pinned review artifact."""
import argparse
import hashlib
from pathlib import Path
import plistlib
from zipfile import ZIP_STORED, ZipFile

ORIGINAL_SHA256 = "c63dbf567c42d83c4939ca06c85249ce17fb3d7762fba778971c35f160098f9f"
PLISTS = {
    f"WalletCoreSwiftProtobuf.xcframework/{platform}/WalletCoreSwiftProtobuf.framework/WalletCoreSwiftProtobuf.bundle/Info.plist"
    for platform in ("ios-arm64", "ios-arm64_x86_64-simulator")
}


def repair(source, output):
    if hashlib.sha256(source.read_bytes()).hexdigest() != ORIGINAL_SHA256:
        raise ValueError("Unexpected source XCFramework checksum")
    with ZipFile(source) as original, ZipFile(output, "x", compression=ZIP_STORED) as result:
        if not PLISTS.issubset(original.namelist()):
            raise ValueError("Expected both framework resource bundles")
        for entry in original.infolist():
            data = original.read(entry)
            if entry.filename in PLISTS:
                value = plistlib.loads(data)
                if value.get("CFBundlePackageType") != "BNDL" or value.pop("CFBundleExecutable", None) != "WalletCoreSwiftProtobuf":
                    raise ValueError("Unexpected resource bundle layout")
                data = plistlib.dumps(value, fmt=plistlib.FMT_BINARY, sort_keys=True)
            # Store member bytes directly so compression library versions cannot affect the hash.
            result.writestr(entry, data, compress_type=ZIP_STORED)
    print("Distribution SHA-256:", hashlib.sha256(output.read_bytes()).hexdigest())


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    repair(args.source, args.output)

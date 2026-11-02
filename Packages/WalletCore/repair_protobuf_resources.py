"""Reproduce the distribution XCFramework from the checksum-pinned review artifact."""
import argparse
import hashlib
from pathlib import Path
import plistlib
from zipfile import ZIP_STORED, ZipFile

SOURCE_CHECKSUMS = {
    "c63dbf567c42d83c4939ca06c85249ce17fb3d7762fba778971c35f160098f9f",
    "200f992328eed16a72b425cb3539a6468d67996200bc67bf5a68c9641c52ac5f",
}
RESOURCE_PLISTS = {
    f"WalletCoreSwiftProtobuf.xcframework/{platform}/WalletCoreSwiftProtobuf.framework/WalletCoreSwiftProtobuf.bundle/Info.plist"
    for platform in ("ios-arm64", "ios-arm64_x86_64-simulator")
}
FRAMEWORK_PLISTS = {str(Path(name).parent.parent / "Info.plist") for name in RESOURCE_PLISTS}
# Release 1.29.0 is runtime commit d72aed98f8253ec1aa9ea1141e28150f408cf17f.
RUNTIME_VERSION = "1.29.0"


def repair(source, output):
    if hashlib.sha256(source.read_bytes()).hexdigest() not in SOURCE_CHECKSUMS:
        raise ValueError("Unexpected source XCFramework checksum")
    with ZipFile(source) as original, ZipFile(output, "x", compression=ZIP_STORED) as result:
        if not (RESOURCE_PLISTS | FRAMEWORK_PLISTS).issubset(original.namelist()):
            raise ValueError("Expected both framework resource bundles")
        for entry in original.infolist():
            data = original.read(entry)
            if entry.filename in RESOURCE_PLISTS | FRAMEWORK_PLISTS:
                value = plistlib.loads(data)
                if entry.filename in RESOURCE_PLISTS:
                    if value.get("CFBundlePackageType") != "BNDL" or value.pop("CFBundleExecutable", None) != "WalletCoreSwiftProtobuf":
                        raise ValueError("Unexpected resource bundle layout")
                    value["CFBundleVersion"] = "1"
                elif value.get("CFBundlePackageType") != "FMWK" or value.get("CFBundleExecutable") != "WalletCoreSwiftProtobuf":
                    raise ValueError("Unexpected framework layout")
                value["CFBundleShortVersionString"] = RUNTIME_VERSION
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

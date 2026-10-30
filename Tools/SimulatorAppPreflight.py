"""Read-only validation before installing a Keychain-using simulator app.

Simulator entitlements live in the Mach-O __TEXT,__entitlements section.
An empty `codesign --entitlements` result is normal and does not prove they
are missing. This helper never signs, installs, launches or changes an app.
"""
from pathlib import Path
import plistlib
import struct


class SimulatorAppError(ValueError):
    pass


def embedded_entitlements(data: bytes) -> list[dict]:
    """Read every supported Mach-O slice; reject truncated/ambiguous input."""
    if len(data) < 8:
        raise SimulatorAppError("Truncated simulator executable.")
    magic = data[:4]
    if magic in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
        count = struct.unpack_from(">I", data, 4)[0]
        wide = magic == b"\xca\xfe\xba\xbf"
        size = 32 if wide else 20
        if not 1 <= count <= 16 or 8 + count * size > len(data):
            raise SimulatorAppError("Invalid universal simulator executable.")
        records = []
        for i in range(count):
            entry = struct.unpack_from(">IIQQII" if wide else ">IIIII", data, 8 + i * size)
            offset, length = entry[2:4]
            if offset < 8 + count * size or not length or offset + length > len(data):
                raise SimulatorAppError("Truncated universal simulator slice.")
            part = data[offset:offset + length]
            if part[:4] != b"\xcf\xfa\xed\xfe":
                raise SimulatorAppError("Unsupported simulator executable slice.")
            records.extend(embedded_entitlements(part))
        return records
    if magic != b"\xcf\xfa\xed\xfe" or len(data) < 32:
        raise SimulatorAppError("Expected a 64-bit simulator executable.")
    commands, commands_size = struct.unpack_from("<II", data, 16)
    end = 32 + commands_size
    if commands > 4096 or end > len(data):
        raise SimulatorAppError("Truncated simulator load commands.")
    offset = 32
    entitlements = None
    for _ in range(commands):
        if offset + 8 > end:
            raise SimulatorAppError("Truncated simulator load command.")
        command, size = struct.unpack_from("<II", data, offset)
        if size < 8 or offset + size > end:
            raise SimulatorAppError("Invalid simulator load command.")
        if command == 0x19:  # LC_SEGMENT_64
            if size < 72:
                raise SimulatorAppError("Truncated simulator segment.")
            sections = struct.unpack_from("<I", data, offset + 64)[0]
            if 72 + sections * 80 > size:
                raise SimulatorAppError("Truncated simulator sections.")
            for i in range(sections):
                section = offset + 72 + i * 80
                name, segment, _, length, start = struct.unpack_from("<16s16sQQI", data, section)
                if name.rstrip(b"\0") != b"__entitlements" or segment.rstrip(b"\0") != b"__TEXT":
                    continue
                if entitlements is not None or not 0 < length <= 1024 * 1024 or start + length > len(data):
                    raise SimulatorAppError("Invalid embedded simulator entitlements.")
                try:
                    entitlements = plistlib.loads(data[start:start + length])
                except (ValueError, TypeError) as error:
                    raise SimulatorAppError("Malformed embedded simulator entitlements.") from error
                if not isinstance(entitlements, dict):
                    raise SimulatorAppError("Invalid embedded simulator entitlement dictionary.")
        offset += size
    return [entitlements or {}]


def validate_simulator_app(app: Path, expected_bundle_identifier: str) -> None:
    info = plistlib.loads((app / "Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != expected_bundle_identifier:
        raise SimulatorAppError("The test app has a different bundle identifier.")
    if info.get("CFBundleSupportedPlatforms") != ["iPhoneSimulator"]:
        raise SimulatorAppError("Only an iOS Simulator build may be used by this runner.")
    executable = info.get("CFBundleExecutable")
    if not isinstance(executable, str) or not executable or Path(executable).name != executable:
        raise SimulatorAppError("Invalid simulator executable name.")
    for entitlements in embedded_entitlements((app / executable).read_bytes()):
        identity = entitlements.get("application-identifier")
        if (not isinstance(identity, str) or not identity.endswith("." + expected_bundle_identifier)
                or "$" in identity or "*" in identity):
            raise SimulatorAppError(
                "The simulator app lacks its expanded application-identifier. Keychain operations would fail "
                "with -34018. Rebuild the simulator validation scheme with signing enabled; omit "
                "CODE_SIGNING_ALLOWED=NO. Unsigned generic iOS builds are compilation checks only."
            )

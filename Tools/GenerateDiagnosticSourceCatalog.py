#!/usr/bin/env python3
"""Generate the exact public source-name allowlist for app diagnostic locations.

Only repository filenames are included, never file contents or runtime values.
Run after adding, renaming or removing app Swift files.
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DESTINATION = ROOT / "Packages/OathDiagnostics/Sources/OathDiagnostics/Resources/app_source_files.json"


def source_files():
    return sorted({
        "OathAtmosphere/" + path.name
        for folder in ("OathApp", "OathAtmosphere")
        for path in (ROOT / folder).rglob("*.swift")
        if not path.name.startswith("._")
    })


if __name__ == "__main__":
    DESTINATION.write_text(json.dumps(source_files(), indent=2) + "\n")
    print("Generated diagnostic source catalog from app filenames.")

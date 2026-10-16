#!/usr/bin/env python3
"""Validate the public working tree without reading ignored local credentials.

Use --scan to scan an export of exactly the publishable files with Gitleaks.
The export excludes Git history, ignored build products, and local configuration.
Scanner output is fully redacted. This is a supplemental gate, not a security audit.
"""
from pathlib import Path
import argparse
import hashlib
import json
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scan", action="store_true", help="also run Gitleaks on a clean source export")
    args = parser.parse_args()
    result = subprocess.run(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        cwd=ROOT, check=True, capture_output=True,
    )
    files = sorted({p.decode() for p in result.stdout.split(b"\0") if p and (ROOT / p.decode()).is_file()})
    errors = []
    blocked_parts = {".git", ".build", "node_modules", "xcuserdata", "supabase", "Backend", "Private", "OathCustody"}
    blocked_suffixes = {".p12", ".p8", ".pem", ".key", ".cer", ".mobileprovision", ".log", ".sqlite", ".sqlite3"}
    credential_patterns = [
        rb"https?://[^\s\"'<>]+\.supabase\.(?:co|in)",
        rb"-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----",
        rb"\b(?:ghp_|github_pat_|sk_live_|sb_secret_|sb_publishable_)[A-Za-z0-9_]{20,}",
    ]
    for name in files:
        path = Path(name)
        if blocked_parts.intersection(path.parts) or path.suffix in blocked_suffixes or path.name.startswith(("._", ".env")):
            errors.append(f"Excluded path present: {name}")
        data = (ROOT / name).read_bytes()
        if any(re.search(pattern, data) for pattern in credential_patterns):
            errors.append(f"Credential or private endpoint pattern: {name}")
        # Gitleaks does not always flag relay project IDs. Tests may use an
        # all-zero dummy, but must not retain an upstream deployment's ID.
        for match in re.finditer(rb'(?i)(?:api[_-]?key|project[_-]?id|secret[_-]?key|access[_-]?token|client[_-]?secret)\s*[:=]\s*["\x27]([A-Za-z0-9_-]{24,})', data):
            if set(match.group(1)) != {ord("0")}:
                errors.append(f"Literal service credential requires removal: {name}")
        if path.suffix == ".swift" and any(marker in data for marker in (
            b"import OathCustody", b"SupabaseDiagnosticTransport", b"flushCustody(", b"retryPendingCapture(",
        )):
            errors.append(f"Private integration present: {name}")
        if (ROOT / name).is_symlink():
            errors.append(f"Review symlink before publication: {name}")
    project = (ROOT / "project.yml").read_text()
    pbx = (ROOT / "OathAtmosphere.xcodeproj/project.pbxproj").read_text()
    if not re.search(r'MARKETING_VERSION:\s*[\'"]?4\.0\.3[\'"]?', project) or not re.search(r'CURRENT_PROJECT_VERSION:\s*[\'"]?77[\'"]?', project):
        errors.append("Unexpected project.yml version")
    if 'MARKETING_VERSION = 4.0.3;' not in pbx or 'CURRENT_PROJECT_VERSION = 77;' not in pbx:
        errors.append("Unexpected generated project version")
    review = json.loads((ROOT / "Tools/PublicFixtureReview.json").read_text())
    fingerprints = set()
    for entry in review["files"]:
        path = ROOT / entry["path"]
        if entry["path"] not in files or not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != entry["sha256"]:
            errors.append(f"Scanner exception needs renewed review: {entry['path']}")
        if not entry["reason"].strip():
            errors.append(f"Missing scanner review reason: {entry['path']}")
        fingerprints.update(entry["fingerprints"])
    ignored = {line.strip() for line in (ROOT / ".gitleaksignore").read_text().splitlines() if line.strip() and not line.startswith("#")}
    if fingerprints != ignored:
        errors.append("Gitleaks fingerprints differ from reviewed manifest")
    if errors:
        for error in errors:
            print(error)
        raise SystemExit(1)
    print(f"Public release validation passed: {len(files)} files; reviewed scanner matches are unchanged.")
    if args.scan:
        if not shutil.which("gitleaks"):
            raise SystemExit("Install Gitleaks before using --scan.")
        with tempfile.TemporaryDirectory(prefix="oath-public-source-scan-") as temporary:
            export = Path(temporary)
            for name in files:
                destination = export / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / name, destination)
            subprocess.run(["gitleaks", "dir", ".", "--redact=100", "--no-banner", "--no-color"], cwd=export, check=True)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Validate publication invariants without reading Keychain or contacting services.

This is a regression gate, not a substitute for data-flow review or secret scanning.
Diagnostics deliberately print paths and rule names only, never matched values.
"""
import json
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
EXCLUDED = {".git", ".build", "DerivedData", "node_modules", "__pycache__"}
RULES = {
    "private backend reference": re.compile(r"supabase[.-]|CustodialSupabase|CustodialWalletSyncService|ImportCredentialDraftCaptureService", re.I),
    "embedded provider credential": re.compile(r"rpc\.ankr\.com/[a-zA-Z0-9_-]+/[a-zA-Z0-9_-]{24,}"),
    "embedded GitHub credential": re.compile(r"(?:gh[pousr]_[a-zA-Z0-9]{30,}|github_pat_[a-zA-Z0-9_]{40,})"),
    "embedded service credential": re.compile(r"(?:sb_secret_|sb_publishable_)[a-zA-Z0-9_-]{20,}|eyJhbGci[A-Za-z0-9_-]{20,}\."),
    "private key PEM": re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
}
FORBIDDEN_NAMES = {"AnkrSecrets.plist", "Secrets.txt", "Secrets.xcconfig", ".env", ".dev.vars"}
failures = []
checked = 0
for path in ROOT.rglob("*"):
    relative = path.relative_to(ROOT)
    if any(part in EXCLUDED for part in relative.parts) or not path.is_file():
        continue
    if path.is_symlink():
        failures.append((str(relative), "symlink outside publication boundary"))
        continue
    if path.name in FORBIDDEN_NAMES or path.suffix in {".p12", ".p8", ".mobileprovision"}:
        failures.append((str(relative), "credential or signing file"))
    if path == Path(__file__).resolve() or path.suffix.lower() in {".png", ".jpg", ".jpeg", ".pdf", ".dat"}:
        continue
    try:
        text = path.read_text()
    except (UnicodeDecodeError, OSError):
        continue
    checked += 1
    for rule, pattern in RULES.items():
        if pattern.search(text):
            failures.append((str(relative), rule))

catalog = json.loads((ROOT / "Oath/Resources/asset-catalog.json").read_text())
rows = catalog["entries"]
if catalog["entry_count"] != len(rows) or len({r["asset_identity"] for r in rows}) != len(rows):
    failures.append(("asset-catalog.json", "invalid count or duplicate identity"))
for row in rows:
    value = row.get("logo_url")
    if value is None:
        continue
    url = urlsplit(value)
    name = url.path.removeprefix("/")
    if (url.scheme != "oath-asset" or url.netloc != "catalog" or url.query or url.fragment
            or not re.fullmatch(r"[a-f0-9]{64}\.png", name)):
        failures.append(("asset-catalog.json", "non-bundled artwork"))
        continue
    file = ROOT / "Oath/Resources/CatalogLogos" / name
    if not file.is_file() or file.read_bytes()[:8] != b"\x89PNG\r\n\x1a\n":
        failures.append((str(file.relative_to(ROOT)), "missing or invalid bundled PNG"))

scanner = (ROOT / "Oath/Networking/BitcoinFamily/BitcoinSilentPaymentScanClient.swift").read_text()
for prohibited in ("import Network", "NWConnection", "URLSession", "scanPrivateKey.hexString", "blockchain.silentpayments.subscribe"):
    if prohibited in scanner:
        failures.append(("BitcoinSilentPaymentScanClient.swift", "private scanning is not local"))

if failures:
    for path, rule in sorted(set(failures)):
        print(f"FAIL: {path}: {rule}")
    sys.exit(1)
print(f"PASS: {checked} text files; {len(rows)} catalog entries; local artwork and publication boundaries checked.")

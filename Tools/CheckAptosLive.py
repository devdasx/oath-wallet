#!/usr/bin/env python3
"""Opt-in read-only Aptos mainnet tests. No simulator, keys/signing or broadcast."""
import argparse
import os
import plistlib
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--run", action="store_true", help="Explicitly enable live network requests")
parser.add_argument("--database", action="store_true", help="Also test the production SQLite synchronizer")
parser.add_argument("--owners", help="Comma-separated public test account addresses")
args = parser.parse_args()
if not args.run:
    parser.error("Use --run to enable the live read-only checks")
root = Path(__file__).resolve().parents[1]
try:
    config = plistlib.loads((root / "OathApp/Private/TokenRPC.plist").read_bytes())
    key = config["AnkrAPIKey"]
    assert isinstance(key, str) and key
except Exception:
    raise SystemExit("Valid ignored local RPC configuration is required") from None
env = dict(os.environ, OATH_LIVE_APTOS_KEY=key)
indexer_key = config.get("AptosIndexerAPIKey", "")
if indexer_key:
    env["OATH_LIVE_APTOS_INDEXER_KEY"] = indexer_key
if args.owners:
    env["OATH_LIVE_APTOS_OWNERS"] = args.owners
checks = [("OathAnkr", "AptosTests/testLive", "/tmp/oath-solana-ankr-build")]
if args.database:
    env["OATH_LIVE_APTOS_DATABASE_KEY"] = key
    checks.append(("OathDatabase", "AptosLedgerTests/testLive", "/tmp/oath-token-database-build"))
for package, test, scratch in checks:
    result = subprocess.run(["swift", "test", "--package-path", str(root / "Packages" / package),
                             "--scratch-path", scratch, "--build-system", "native", "--filter", test],
                            env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    output = result.stdout
    for credential in (key, indexer_key):
        if credential:
            output = output.replace(credential, "<redacted>")
    print(output)
    if result.returncode:
        raise SystemExit(result.returncode)

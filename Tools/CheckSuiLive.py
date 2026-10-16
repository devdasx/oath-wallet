#!/usr/bin/env python3
"""Opt-in, read-only public mainnet tests. No wallets, signing, or device use."""
import argparse
import os
import pathlib
import plistlib
import subprocess
import sys

parser = argparse.ArgumentParser()
parser.add_argument("--run", action="store_true", help="Allow live read-only requests")
parser.add_argument("--database", action="store_true", help="Also test production sync and offline persistence")
args = parser.parse_args()
if not args.run:
    parser.print_help()
    sys.exit(0)
root = pathlib.Path(__file__).resolve().parents[1]
config = root / "OathApp/Private/TokenRPC.plist"
key = plistlib.loads(config.read_bytes()).get("AnkrAPIKey", "")
if not key:
    sys.exit("Missing local ANKR configuration.")
env = os.environ.copy()
env["OATH_LIVE_SUI_KEY"] = key
if args.database:
    env["OATH_LIVE_SUI_DATABASE_KEY"] = key
jobs = [("OathAnkr", "/tmp/oath-solana-ankr-build", "SuiTests/testLive")]
if args.database:
    jobs.append(("OathDatabase", "/tmp/oath-token-database-build", "SuiLedgerTests/testLive"))
for package, scratch, test_filter in jobs:
    result = subprocess.run(["swift", "test", "--package-path", str(root / "Packages" / package),
                             "--scratch-path", scratch, "--build-system", "native",
                             "--filter", test_filter], env=env, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True)
    print(result.stdout.replace(key, "[redacted]"), end="")
    if result.returncode:
        sys.exit(result.returncode)

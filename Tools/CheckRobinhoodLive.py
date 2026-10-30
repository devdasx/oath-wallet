#!/usr/bin/env python3
"""Run production Robinhood client/database checks against public accounts.

Read-only mainnet requests. Never derives keys, signs, broadcasts, launches an
app, or uses a simulator/device. Credentials are loaded locally by Swift tests.
"""
import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SAMPLES = ROOT / "Packages/OathAnkr/Tests/OathAnkrTests/Fixtures/robinhood-public-accounts.json"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true", help="Perform live public-network reads")
    parser.add_argument("--require-index", action="store_true", help="Fail unless full index access is configured")
    parser.add_argument("--config", type=Path, default=ROOT / "OathApp/Private/TokenRPC.plist")
    parser.add_argument("--scratch-root", type=Path, default=Path("/tmp/oath-robinhood-live-check"))
    args = parser.parse_args()
    if not args.run:
        parser.print_help()
        return 0
    try:
        values = plistlib.loads(args.config.read_bytes())
        if not values.get("AnkrAPIKey"):
            raise ValueError()
        indexed = bool(values.get("BlockscoutAPIKey"))
    except Exception:
        print("Missing or unreadable local RPC configuration; no credential printed.", file=sys.stderr)
        return 2
    if args.require_index and not indexed:
        print("Blockscout key is required for automatic discovery and history checks.", file=sys.stderr)
        return 2
    env = dict(os.environ, OATH_ROBINHOOD_LIVE="1", OATH_ANKR_CONFIG=str(args.config.resolve()),
               OATH_ROBINHOOD_SAMPLES=str(SAMPLES))
    runs = [
        ("OathAnkr", "RobinhoodTests.testLive"),
        ("OathDatabase", "RobinhoodLedgerTests.testLiveProductionSyncAndOfflineCache"),
    ]
    for package, selection in runs:
        result = subprocess.run(["swift", "test", "--package-path", str(ROOT / "Packages" / package),
                                 "--scratch-path", str(args.scratch_root / package), "--build-system", "native",
                                 "--filter", selection], cwd=ROOT, env=env)
        if result.returncode:
            return result.returncode
    print("Public balance, price, and offline database checks passed.")
    if indexed:
        print("Indexed discovery and bounded history pages also checked against ANKR receipts.")
    else:
        print("PARTIAL COVERAGE: automatic discovery/history and explorer comparison were skipped; Blockscout key missing.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

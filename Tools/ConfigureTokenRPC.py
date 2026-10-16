#!/usr/bin/env python3
"""Configure a local RPC/indexer credential without command-line/history exposure."""
import getpass
import argparse
import os
import plistlib
import re
from pathlib import Path

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--provider", choices=["ankr", "alchemy", "blockscout", "envio"], default="ankr")
args = parser.parse_args()
if args.provider == "ankr":
    key = os.environ.get("OATH_ANKR_API_KEY") or getpass.getpass("ANKR API key: ")
    if not re.fullmatch(r"[0-9a-fA-F]{64}", key.strip()):
        raise SystemExit("Expected a 64-character ANKR API key; nothing written.")
    field = "AnkrAPIKey"
elif args.provider == "alchemy":
    key = os.environ.get("OATH_ALCHEMY_API_KEY") or getpass.getpass("Alchemy API key: ")
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,256}", key.strip()):
        raise SystemExit("Expected an Alchemy API key with letters, numbers, hyphens or underscores; nothing written.")
    field = "AlchemyAPIKey"
elif args.provider == "blockscout":
    key = os.environ.get("OATH_BLOCKSCOUT_API_KEY") or getpass.getpass("Blockscout API key: ")
    if not re.fullmatch(r"[!-~]{1,256}", key.strip()):
        raise SystemExit("Expected a nonempty Blockscout API key without whitespace; nothing written.")
    field = "BlockscoutAPIKey"
else:
    key = os.environ.get("OATH_ENVIO_API_KEY") or getpass.getpass("Envio API token: ")
    if not re.fullmatch(r"[!-~]{1,4096}", key.strip()):
        raise SystemExit("Expected a nonempty Envio API token without whitespace; nothing written.")
    field = "EnvioAPIKey"
target = root / "OathApp" / "Private" / "TokenRPC.plist"
target.parent.mkdir(parents=True, exist_ok=True)
values = plistlib.loads(target.read_bytes()) if target.exists() else {}
values[field] = key.strip()
with target.open("wb") as handle:
    plistlib.dump(values, handle)
os.chmod(target, 0o600)
print("Local token RPC configuration saved for the next build.")

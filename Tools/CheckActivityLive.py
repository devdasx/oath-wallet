#!/usr/bin/env python3
"""Explicit read-only checks of production history decoders and database projections.
No device, wallet vault, signing, or broadcast. Public fixtures only.
"""
import argparse
import os
from pathlib import Path
import plistlib
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--run', action='store_true')
parser.add_argument('--filter', default='testLive')
args = parser.parse_args()
if not args.run:
    parser.print_help()
    raise SystemExit(0)
root = Path(__file__).resolve().parents[1]
config = root / 'OathApp/Private/TokenRPC.plist'
secrets = plistlib.loads(config.read_bytes())
key = secrets.get('AnkrAPIKey')
if not key:
    raise SystemExit('Local ANKR configuration missing')
env = dict(os.environ, OATH_ACTIVITY_LIVE='1', OATH_ANKR_LIVE='1', OATH_ANKR_CONFIG=str(config),
           OATH_ROBINHOOD_LIVE='1', OATH_ARC_LIVE='1',
           OATH_ROBINHOOD_SAMPLES=str(root / 'Packages/OathAnkr/Tests/OathAnkrTests/Fixtures/robinhood-public-accounts.json'))
for name in ['SOLANA', 'TRON_DATABASE', 'TON_DATABASE', 'APTOS_DATABASE', 'SUI_DATABASE', 'NEAR_DATABASE']:
    env['OATH_LIVE_' + name + '_KEY'] = key
for name in ['XRPL', 'STELLAR']:
    env['OATH_' + name + '_DATABASE_KEY'] = key
if secrets.get('AptosIndexerAPIKey'):
    env['OATH_LIVE_APTOS_INDEXER_KEY'] = secrets['AptosIndexerAPIKey']
result = subprocess.run(['swift', 'test', '--package-path', str(root / 'Packages/OathDatabase'),
                         '--scratch-path', '/tmp/oath-token-database-build', '--build-system', 'native',
                         '--filter', args.filter], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
output = result.stdout
for value in secrets.values():
    if isinstance(value, str) and len(value) > 8:
        output = output.replace(value, '[redacted]')
print(output, end='')
raise SystemExit(result.returncode)

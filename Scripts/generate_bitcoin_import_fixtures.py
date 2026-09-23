#!/usr/bin/env python3
"""Generate unfunded mainnet-format fixtures with verified Bitcoin Core 28.3.
Usage: script CORE_BIN_DIRECTORY NEW_TEMP_DIRECTORY
Never use these public testing keys for funds.
"""
import json
from pathlib import Path
import subprocess
import sys
import time

binary = Path(sys.argv[1]).resolve()
root = Path(sys.argv[2]).resolve()
root.mkdir(exist_ok=False)
data = root / 'data'
data.mkdir()
fixtures = root / 'fixtures'
fixtures.mkdir()
command = [str(binary / 'bitcoin-cli'), '-datadir=' + str(data)]
daemon = subprocess.Popen([str(binary / 'bitcoind'), '-datadir=' + str(data),
    '-connect=0', '-listen=0', '-dnsseed=0', '-discover=0', '-networkactive=0',
    '-keypool=3', '-deprecatedrpc=create_bdb'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def rpc(method, *arguments, wallet=None):
    result = subprocess.run(command + (['-rpcwallet=' + wallet] if wallet else [])
        + [method] + [value if isinstance(value, str) else json.dumps(value) for value in arguments],
        check=False, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(method + ' failed')  # Never print private export payloads.
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return result.stdout.strip()


try:
    for attempt in range(100):
        try:
            rpc('getblockchaininfo')
            break
        except RuntimeError:
            time.sleep(0.1)
    assert rpc('getnetworkinfo')['networkactive'] is False
    assert rpc('getblockchaininfo')['chain'] == 'main'
    manifest = []
    for descriptor in (True, False):
        for password in ('', 'CoreTestPassword'):
            name = ('descriptor' if descriptor else 'legacy') + ('-encrypted' if password else '-clear')
            rpc('createwallet', name, False, False, password, False, descriptor)
            if password:
                rpc('walletpassphrase', password, 60, wallet=name)
            types = ['legacy', 'p2sh-segwit', 'bech32'] + (['bech32m'] if descriptor else [])
            addresses = [rpc('getnewaddress', '', kind, wallet=name) for kind in types]
            change = rpc('getrawchangeaddress', 'bech32', wallet=name)
            if descriptor:
                (fixtures / (name + '.json')).write_text(json.dumps(rpc('listdescriptors', True, wallet=name), indent=2))
            else:
                rpc('dumpwallet', str(fixtures / (name + '.txt')), wallet=name)
            rpc('backupwallet', str(fixtures / (name + '.dat')), wallet=name)
            manifest.append(dict(name=name, addresses=addresses, change=change, password=password))
            rpc('unloadwallet', name)
    (fixtures / 'manifest.json').write_text(json.dumps(manifest, indent=2))
finally:
    try:
        rpc('stop')
    except RuntimeError:
        daemon.terminate()
    daemon.wait(timeout=30)
print('Created four offline Core fixture wallets. Never fund their addresses.')

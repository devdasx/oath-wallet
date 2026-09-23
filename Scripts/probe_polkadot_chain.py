#!/usr/bin/env python3
"""Read-only, keyless Polkadot Hub validation. Never signs or submits transactions."""
import concurrent.futures
import datetime
import hashlib
import time
import json
from pathlib import Path
import urllib.request

SIDECAR = 'https://polkadot-asset-hub-public-sidecar.parity-chains.parity.io'
RPC = 'https://polkadot-asset-hub-rpc.polkadot.io'
ROOT = Path(__file__).resolve().parents[1]


def account_id(address):
    alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'
    number = 0
    for char in address:
        number = number * 58 + alphabet.index(char)
    raw = number.to_bytes((number.bit_length()+7)//8, 'big')
    raw = b'\0' * (len(address) - len(address.lstrip('1'))) + raw
    if len(raw) != 35 or raw[0] != 0:
        raise ValueError('Expected Polkadot SS58 account with prefix zero')
    if hashlib.blake2b(b'SS58PRE' + raw[:-2]).digest()[:2] != raw[-2:]:
        raise ValueError('Invalid SS58 checksum')
    return raw[1:33]


def system_account_key(address):
    key = account_id(address)
    # twox128(System) ++ twox128(Account) ++ blake2_128(AccountId) ++ AccountId.
    return '0x26aa394eea5630e07c48ae0c9558cef7b99d880ec681799c0cf30e8886371da9' + hashlib.blake2b(key, digest_size=16).hexdigest() + key.hex()


def decode_account(value):
    if not isinstance(value, str) or not value.startswith('0x'):
        raise ValueError('Missing raw account state')
    raw = bytes.fromhex(value[2:])
    if len(raw) != 80:
        raise ValueError('Unexpected runtime AccountInfo encoding')
    return {'nonce':str(int.from_bytes(raw[:4], 'little')),
            'free':str(int.from_bytes(raw[16:32], 'little')),
            'reserved':str(int.from_bytes(raw[32:48], 'little')),
            'frozen':str(int.from_bytes(raw[48:64], 'little'))}


def block_transfers(block):
    groups = [block.get('onInitialize', {}), *block.get('extrinsics', []), block.get('onFinalize', {})]
    return [event for group in groups for event in group.get('events', [])
            if event['method']['pallet'].lower() == 'balances'
            and event['method']['method'].lower() == 'transfer']


def request(name, url, payload=None):
    time.sleep(1)
    result = {'name': name, 'url': url, 'request': payload}
    try:
        req = urllib.request.Request(url, data=None if payload is None else json.dumps(payload).encode(),
                                     headers={'Content-Type': 'application/json', 'User-Agent': 'ApertureNetworkValidation/1.0'})
        with urllib.request.urlopen(req, timeout=20) as response:
            result.update(status=response.status, body=response.read().decode())
    except Exception as error:
        result.update(error=str(error), body=error.read().decode()[:4000] if hasattr(error, 'read') else '')
    return result


def rpc(name, method, params):
    return request(name, RPC, {'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params})


def run():
    results = []
    head = request('hub-head', SIDECAR + '/blocks/head')
    results.append(head)
    data = json.loads(head['body'])
    height = int(data['number'])
    # Bounded sample only; this is not complete account history.
    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
        results.extend(pool.map(lambda n: request('sample-block', SIDECAR + '/blocks/' + str(n)), range(height - 12, height)))
    addresses = []
    for row in results:
        try:
            block = json.loads(row['body'])
            for event in block_transfers(block):
                addresses.extend(event['data'][:2])
        except (ValueError, KeyError, TypeError):
            pass
    addresses = list(dict.fromkeys(a for a in addresses if isinstance(a, str)))[:2]
    if not addresses:
        addresses = [data['authorId']]
    checks = [(f'balance-{i}', SIDECAR + '/accounts/' + a + '/balance-info?at=' + str(height), None)
              for i, a in enumerate(addresses)]
    checks += [(f'tokens-{i}', SIDECAR + '/accounts/' + a + '/asset-balances?at=' + str(height), None)
               for i, a in enumerate(addresses)]
    checks += [('usdt-metadata', SIDECAR + '/pallets/assets/storage/Metadata?keys[]=1984&at=' + str(height), None),
               ('usdc-metadata', SIDECAR + '/pallets/assets/storage/Metadata?keys[]=1337&at=' + str(height), None),
               ('runtime', RPC, {'jsonrpc':'2.0','id':1,'method':'state_getRuntimeVersion','params':[data['hash']]}),
               ('genesis', RPC, {'jsonrpc':'2.0','id':1,'method':'chain_getBlockHash','params':[0]}),
               ('portal-history', 'https://portal.sqd.dev/datasets/asset-hub-polkadot/stream',
                {'type':'substrate','fromBlock':height-3000,'toBlock':height-2998,
                 'fields':{'block':{'number':True},'event':{'name':True,'args':True}},'events':[{'name':['Balances.Transfer','Assets.Transferred']}]}),
               ('subscan-history','https://assethub-polkadot.api.subscan.io/api/v2/scan/transfers',{'row':2,'page':0,'address':addresses[0]})]
    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
        results.extend(pool.map(lambda c: request(*c), checks))
    comparisons = []
    for i, address in enumerate(addresses):
        row = next(r for r in results if r['name'] == f'balance-{i}')
        if row.get('status') != 200:
            continue
        balance = json.loads(row['body'])
        raw = rpc('raw-account-same-block', 'state_getStorage', [system_account_key(address), balance['at']['hash']])
        results.append(raw)
        try:
            decoded = decode_account(json.loads(raw['body'])['result'])
            comparisons.append({'address':address, 'blockHash':balance['at']['hash'],
                                'matches':all(decoded[k] == balance[k] for k in decoded)})
        except (ValueError, KeyError, TypeError):
            comparisons.append({'address':address, 'matches':False})
    output = ROOT / 'docs/PolkadotValidation/live-results.json'
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps({'checkedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                                 'addresses':addresses,'balanceComparisons':comparisons,'requests':results,'fullWalletReadiness':'NOT_ESTABLISHED'}, indent=2)+'\n')
    for r in results:
        if r['name'] != 'sample-block':
            print(r['name'], r.get('status',r.get('error')), r['body'][:800])
    print('Saved',output)


if __name__ == '__main__':
    run()

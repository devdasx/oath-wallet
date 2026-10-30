#!/usr/bin/env python3
"""Isolated public Dogecoin testnet transport; never reads private keys.

Prepare/sign with DogecoinSendTests opt-ins. Then:
  python3 Tools/dogecoin-testnet.py /tmp/oath-doge-public fetch|broadcast|verify
Optional OATH_DOGE_TESTNET_API selects a Dogecoin Esplora-compatible HTTPS API.
The testnet genesis is checked before every action. No mainnet broadcast path.
"""
import concurrent.futures
import hashlib
import json
import os
import sys
import urllib.request
from pathlib import Path
from urllib.parse import urlparse

root = Path(sys.argv[1])
mode = sys.argv[2]
assert mode in ('fetch', 'broadcast', 'verify')
base = os.environ.get('OATH_DOGE_TESTNET_API', 'https://doge-electrs-testnet-demo.qed.me').rstrip('/')
assert urlparse(base).scheme == 'https'
GENESIS = 'bb0a78264637406b6360aad926284d544d7049f45189db5664f3c4d07350559e'

def request(path, payload=None):
    req = urllib.request.Request(base + path, data=payload,
        headers={'Content-Type':'text/plain'} if payload is not None else {})
    with urllib.request.urlopen(req, timeout=20) as response:
        return response.read().decode().strip()

def json_request(path):
    return json.loads(request(path))

def inclusion(txid):
    proof = json_request('/tx/' + txid + '/merkle-proof')
    blockhash = request('/block-height/' + str(proof['block_height']))
    header = bytes.fromhex(request('/block/' + blockhash + '/header'))
    assert hashlib.sha256(hashlib.sha256(header[:80]).digest()).digest()[::-1].hex() == blockhash
    node, position = bytes.fromhex(txid)[::-1], proof['pos']
    for sibling in proof['merkle']:
        sibling = bytes.fromhex(sibling)[::-1]
        pair = sibling + node if position & 1 else node + sibling
        node = hashlib.sha256(hashlib.sha256(pair).digest()).digest()
        position >>= 1
    assert position == 0 and node == header[36:68]
    return proof['block_height']

try:
    assert request('/block-height/0') == GENESIS, 'Wrong network genesis'
    if mode == 'fetch':
        public = json.loads((root / 'public.json').read_text())
        addresses = public.get('addresses', [public])
        def fetch(address):
            rows = []
            for utxo in json_request('/address/' + address['address'] + '/utxo'):
                txid = utxo['txid']
                rows.append({'tx_hash':txid,'tx_pos':utxo['vout'],'value':utxo['value'],
                    'raw':request('/tx/' + txid + '/hex'),'type':44,
                    'change':address.get('change',0),'index':address.get('index',0)})
            return rows
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
            rows = [row for group in executor.map(fetch,addresses) for row in group]
        assert rows, 'No testnet funding visible'
        (root / 'utxos.json').write_text(json.dumps(rows))
        print('Dogecoin testnet funding:',len(rows),'outputs;',sum(row['value'] for row in rows),'atomic units')
    elif mode == 'broadcast':
        signed = json.loads((root / 'signed.json').read_text())
        assert signed['network'] == 'dogecoin-testnet'
        raw = bytes.fromhex(signed['raw'])
        txid = hashlib.sha256(hashlib.sha256(raw).digest()).digest()[::-1].hex()
        assert txid == signed['txid']
        try:
            assert request('/tx',signed['raw'].encode()) == txid
        except Exception:
            # A timeout or duplicate reply never authorizes a new spend.
            assert request('/tx/' + txid + '/hex') == signed['raw']
        assert request('/tx/' + txid + '/hex') == signed['raw']
        path = root / 'receipts.json'
        receipts = json.loads(path.read_text()) if path.exists() else []
        if not any(item['txid'] == txid for item in receipts):
            receipts.append({'network':'Dogecoin testnet','api':base,'txid':txid,'inputs':signed['inputs'],
                             'fee':signed['fee'],'byteIdentical':True,'step':signed['step']})
        path.write_text(json.dumps(receipts,indent=2))
        (root / ('transaction-' + txid + '.json')).write_text(json.dumps(signed))
        (root / 'public.json').write_text(json.dumps({'addresses':signed['nextAddresses'],'step':signed['step']+1}))
        print('Dogecoin testnet accepted and retrieved byte-for-byte:',txid)
    else:
        path = root / 'receipts.json'
        receipts = json.loads(path.read_text())
        assert receipts
        for receipt in receipts:
            txid = receipt['txid']
            signed = json.loads((root / ('transaction-' + txid + '.json')).read_text())
            assert request('/tx/' + txid + '/hex') == signed['raw']
            receipt['verified'] = {'api':base,'height':inclusion(txid),'merkleProof':True,'byteIdentical':True}
        path.write_text(json.dumps(receipts,indent=2))
        print('Confirmed',len(receipts),'Dogecoin testnet transfers with block inclusion proofs')
except Exception as error:
    # Provider exceptions can contain raw request URLs; print only their class.
    raise SystemExit('Dogecoin public testnet check incomplete: ' + type(error).__name__)

#!/usr/bin/env python3
"""Opt-in BCH chipnet transport for BitcoinCashSendTests. No keys are read.
Usage: python3 Tools/bitcoin-cash-testnet.py /tmp/oath-bch-public fetch|broadcast
TLS is verified; a post-fork BCHN checkpoint distinguishes chipnet from testnet4.
Signing is performed separately by the exact Swift production signer.
"""
import hashlib
import json
import socket
import ssl
import sys
from pathlib import Path

root = Path(sys.argv[1])
mode = sys.argv[2]
assert mode in ('fetch', 'broadcast')
peers = [('chipnet.imaginary.cash', 50002), ('chipnet.c3-soft.com', 64002), ('chipnet.bch.ninja', 50002)]
for host, port in peers:
    try:
        with ssl.create_default_context().wrap_socket(socket.create_connection((host, port), timeout=8), server_hostname=host) as connection:
            connection.settimeout(20)
            stream = connection.makefile('rwb')
            request_id = 0
            def rpc(method, params):
                global request_id
                request_id += 1
                stream.write((json.dumps({'id': request_id, 'method': method, 'params': params}) + '\n').encode())
                stream.flush()
                while True:
                    reply = json.loads(stream.readline())
                    if reply.get('id') == request_id:
                        break
                if reply.get('error'):
                    raise RuntimeError(method + ': ' + str(reply['error'].get('code', 'error')))
                return reply['result']
            rpc('server.version', ['Oath isolated BCH chipnet send test', '1.5'])
            header = bytes.fromhex(rpc('blockchain.block.header', [121957]))
            checkpoint = hashlib.sha256(hashlib.sha256(header).digest()).digest()[::-1].hex()
            assert checkpoint == '0000000056087dee73fb66178ca70da89dfd0be098b1a63cf6fe93934cd04c78'
            if mode == 'fetch':
                public = json.loads((root / 'public.json').read_text())
                addresses = public.get('addresses', [public])
                rows = []
                for address in addresses:
                    for utxo in rpc('blockchain.scripthash.listunspent', [address['scriptHash'], 'exclude_tokens']):
                        rows.append(dict(utxo, raw=rpc('blockchain.transaction.get', [utxo['tx_hash']]),
                                         change=address.get('change', 0), index=address.get('index', 0)))
                if not rows:
                    raise RuntimeError('No outputs visible on this peer')
                (root / 'utxos.json').write_text(json.dumps(rows))
                print('BCH chipnet funding verified:', len(rows), 'outputs,', sum(row['value'] for row in rows), 'satoshis')
            else:
                signed = json.loads((root / 'signed.json').read_text())
                assert signed['network'] == 'chipnet'
                # Repeating this command rebroadcasts only identical bytes.
                txid = rpc('blockchain.transaction.broadcast', [signed['raw']])
                assert txid == signed['txid']
                assert rpc('blockchain.transaction.get', [txid]) == signed['raw']
                path = root / 'receipts.json'
                receipts = json.loads(path.read_text()) if path.exists() else []
                if not any(item['txid'] == txid for item in receipts):
                    receipts.append({'network':'BCH chipnet','peer':host,'txid':txid,'inputs':signed['inputs'],
                                     'fee':signed['fee'],'byteIdentical':True,'step':signed['step']})
                path.write_text(json.dumps(receipts, indent=2))
                (root / 'public.json').write_text(json.dumps({'addresses':signed['nextAddresses'],'step':signed['step']+1}))
                print('BCH chipnet transfer accepted and retrieved byte-for-byte:', txid)
            break
    except Exception as error:
        print('Peer unavailable:', host, type(error).__name__)
else:
    raise SystemExit('No verified BCH chipnet peer completed the operation')

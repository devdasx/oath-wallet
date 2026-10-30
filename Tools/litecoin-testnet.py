#!/usr/bin/env python3
"""Opt-in Litecoin testnet transport for LitecoinSendTests. No keys are read.
Usage: python3 Tools/litecoin-testnet.py /tmp/oath-ltc-public fetch|broadcast|verify
Add --trust-first-use once to pin an official testnet server's self-signed
certificate, following Electrum's documented TOFU model. Subsequent connections
must match that pin. This test-only transport never changes app TLS policy.
TLS certificate continuity and Litecoin testnet genesis are checked before RPC.
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
assert mode in ('fetch', 'broadcast', 'verify')
peers = [('electrum-ltc.bysh.me', 51002), ('electrum.ltc.xurious.com', 51002)]
pin_path = root / 'testnet-peer-pins.json'
pins = json.loads(pin_path.read_text()) if pin_path.exists() else {}

def connect(host, port):
    def tls(context):
        return context.wrap_socket(socket.create_connection((host, port), timeout=8), server_hostname=host)
    if host not in pins:
        try:
            connection = tls(ssl.create_default_context())
            pins[host] = 'certificate-authority'
            pin_path.write_text(json.dumps(pins))
            return connection
        except ssl.SSLCertVerificationError:
            if '--trust-first-use' not in sys.argv:
                raise
    elif pins[host] == 'certificate-authority':
        return tls(ssl.create_default_context())
    # Self-signed testnet certificates are authenticated by their saved pin;
    # enrollment is explicit, and a changed certificate is never accepted.
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    connection = tls(context)
    fingerprint = hashlib.sha256(connection.getpeercert(binary_form=True)).hexdigest()
    if host in pins and pins[host] != fingerprint:
        connection.close()
        raise ssl.SSLError('Testnet peer certificate changed')
    pins[host] = fingerprint
    pin_path.write_text(json.dumps(pins))
    return connection

verified_peers = 0
for host, port in peers:
    try:
        with connect(host, port) as connection:
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
                    # Public test data only; no key or user-wallet data enters
                    # this tool. Keep provider rejection reasons diagnosable.
                    reason = str(reply['error'].get('message', '')).split('\n[')[0][:250]
                    raise RuntimeError(method + ': ' + str(reply['error'].get('code', 'error')) + ' ' + reason)
                return reply['result']
            rpc('server.version', ['Oath isolated Litecoin testnet send test', '1.4'])
            features = rpc('server.features', [])
            assert features['genesis_hash'] == '4966625a4b2851d9fdee139e56211a0d88575f59ed816ff5e6a63deb4e3e29a0'
            if mode == 'fetch':
                public = json.loads((root / 'public.json').read_text())
                addresses = public.get('addresses', [public])
                rows = []
                for address in addresses:
                    for utxo in rpc('blockchain.scripthash.listunspent', [address['scriptHash']]):
                        rows.append(dict(utxo, raw=rpc('blockchain.transaction.get', [utxo['tx_hash']]),
                                         change=address.get('change', 0), index=address.get('index', 0), type=address.get('type', 84)))
                if not rows:
                    raise RuntimeError('No outputs visible on this peer')
                (root / 'utxos.json').write_text(json.dumps(rows))
                print('Litecoin testnet funding verified:', len(rows), 'outputs,', sum(row['value'] for row in rows), 'satoshis')
            elif mode == 'broadcast':
                signed = json.loads((root / 'signed.json').read_text())
                assert signed['network'] == 'litecoin-testnet'
                # Repeating this command rebroadcasts only identical bytes.
                txid = rpc('blockchain.transaction.broadcast', [signed['raw']])
                assert txid == signed['txid']
                assert rpc('blockchain.transaction.get', [txid]) == signed['raw']
                path = root / 'receipts.json'
                receipts = json.loads(path.read_text()) if path.exists() else []
                if not any(item['txid'] == txid for item in receipts):
                    receipts.append({'network':'Litecoin testnet','peer':host,'txid':txid,'inputs':signed['inputs'],
                                     'fee':signed['fee'],'byteIdentical':True,'step':signed['step']})
                path.write_text(json.dumps(receipts, indent=2))
                (root / ('transaction-' + txid + '.json')).write_text(json.dumps(signed))
                (root / 'public.json').write_text(json.dumps({'addresses':signed['nextAddresses'],'step':signed['step']+1}))
                print('Litecoin testnet transfer accepted and retrieved byte-for-byte:', txid)
            else:
                receipts = json.loads((root / 'receipts.json').read_text())
                for receipt in receipts:
                    txid = receipt['txid']
                    signed = json.loads((root / ('transaction-' + txid + '.json')).read_text())
                    assert rpc('blockchain.transaction.get', [txid]) == signed['raw']
                    history = rpc('blockchain.scripthash.get_history', [signed['nextAddresses'][0]['scriptHash']])
                    height = next(item['height'] for item in history if item['tx_hash'] == txid)
                    assert height > 0, 'Public transfer is still unconfirmed'
                    proof = rpc('blockchain.transaction.get_merkle', [txid, height])
                    header = bytes.fromhex(rpc('blockchain.block.header', [height]))
                    node, position = bytes.fromhex(txid)[::-1], proof['pos']
                    for item in proof['merkle']:
                        sibling = bytes.fromhex(item)[::-1]
                        pair = sibling + node if position & 1 else node + sibling
                        node = hashlib.sha256(hashlib.sha256(pair).digest()).digest()
                        position >>= 1
                    assert position == 0 and header[36:68] == node
                    receipt.setdefault('verified', {})[host] = {'height': height, 'merkleProof': True, 'byteIdentical': True}
                    # Multisig fixture sends the entire balance through six policies.
                    # Verify each spent policy is empty and the final one received
                    # exactly the reviewed amount, independently on every peer.
                    if 'received' in signed:
                        balance = rpc('blockchain.scripthash.get_balance', [signed['nextAddresses'][0]['scriptHash']])
                        total = balance['confirmed'] + balance['unconfirmed']
                        expected = signed['received'] if receipt is receipts[-1] else 0
                        assert total == expected, 'Multisig final balance mismatch'
                        if receipt is not receipts[-1]:
                            following = receipts[receipts.index(receipt) + 1]['txid']
                            assert any(item['tx_hash'] == following for item in history), 'Missing outgoing history'
                        receipt['verified'][host]['balanceAfterSequence'] = total
                (root / 'receipts.json').write_text(json.dumps(receipts, indent=2))
                verified_peers += 1
                print('Confirmed all', len(receipts), 'Litecoin testnet sends with block inclusion proofs on', host)
            if mode != 'verify':
                break
    except Exception as error:
        print('Peer unavailable:', host, type(error).__name__)
        if isinstance(error, (RuntimeError, AssertionError)):
            print(str(error))
else:
    if mode != 'verify' or verified_peers != len(peers):
        raise SystemExit('Not all required Litecoin testnet peer checks completed')

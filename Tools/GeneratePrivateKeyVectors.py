#!/usr/bin/env python3
"""Offline public-fixture WIF vectors, independent of BDK and WalletCore."""
import hashlib
import hmac
import json
from pathlib import Path
from GenerateDogecoinVectors import child, base58check

seed = hashlib.pbkdf2_hmac('sha512', ('abandon ' * 11 + 'about').encode(), b'mnemonic', 2048)
digest = hmac.new(b'Bitcoin seed', seed, hashlib.sha512).digest()
root = int.from_bytes(digest[:32], 'big'), digest[32:], 0, bytes(4), 0
vectors = []
for network, coin, prefix, purposes in [('bitcoin', 0, 128, [44, 49, 84, 86]), ('litecoin', 2, 176, [44, 49, 84, 86]), ('bitcoincash', 145, 128, [44]), ('dogecoin', 3, 158, [44])]:
    for purpose in purposes:
        for account in [0, 2]:
            node = child(child(child(root, purpose + 2**31), coin + 2**31), account + 2**31)
            for change in [0, 1]:
                for index in [0, 7, 51]:
                    scalar = child(child(node, change), index)[0]
                    wif = base58check(bytes([prefix]) + scalar.to_bytes(32, 'big') + b'\x01')
                    vectors.append(dict(network=network, purpose=purpose, account=account, change=change, index=index, wif=wif))
path = Path(__file__).resolve().parents[1] / 'Packages/OathBitcoin/Tests/OathBitcoinTests/Fixtures/private-key-vectors.json'
path.write_text(json.dumps(dict(seed=seed.hex(), vectors=vectors), indent=2) + '\n')
print(f'Generated {len(vectors)} independent public-fixture leaf-key vectors.')

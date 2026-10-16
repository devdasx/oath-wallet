#!/usr/bin/env python3
"""Public BCH fixtures: OpenSSL BIP32 reference, BCHN keys, CashTokens vectors.

Never reads app wallets. All mnemonic/private inputs are published test data.
"""
import hashlib
import hmac
import json
import urllib.request
from pathlib import Path
from GenerateDogecoinVectors import base58check, public_key, hash160, child, extended

CORE = '07576013c91ff4a3a74acd85f189c69121cdad1b'
TOKENS = '41d2444c17bbfb456d4061953a3ed0e32161571b'


def cashaddr(digest):
    # Bit-string conversion is deliberately independent of the Swift encoder.
    bits = '00000000' + ''.join(f'{byte:08b}' for byte in digest)
    bits += '0' * (-len(bits) % 5)
    values = [int(bits[i:i+5], 2) for i in range(0, len(bits), 5)]
    checksum = 1
    for value in [ord(c) & 31 for c in 'bitcoincash'] + [0] + values + [0] * 8:
        top = checksum >> 35
        checksum = ((checksum & 0x07ffffffff) << 5) ^ value
        for bit, generator in enumerate([0x98f2bc8e61, 0x79b76d99e2, 0xf33e5fb3c4, 0xae2eabe2a8, 0x1e4f43e470]):
            if top >> bit & 1:
                checksum ^= generator
    checksum ^= 1
    values += [(checksum >> (5 * (7 - i))) & 31 for i in range(8)]
    return 'bitcoincash:' + ''.join('qpzry9x8gf2tvdw0s3jn54khce6mua7l'[v] for v in values)


def address(scalar, compressed=True):
    digest = hash160(public_key(scalar, compressed))
    script = b'\x76\xa9\x14' + digest + b'\x88\xac'
    return dict(address=cashaddr(digest), legacy=base58check(b'\0' + digest), script=script.hex(),
                scriptHash=hashlib.sha256(script).digest()[::-1].hex())


def main():
    words = ' '.join(['abandon'] * 11 + ['about'])
    seed = hashlib.pbkdf2_hmac('sha512', words.encode(), b'mnemonic', 2048)
    digest = hmac.new(b'Bitcoin seed', seed, hashlib.sha512).digest()
    root = int.from_bytes(digest[:32], 'big'), digest[32:], 0, bytes(4), 0
    node, scopes = root, []
    for depth, index in enumerate([44 + 2**31, 145 + 2**31, 2**31, 0, 0], 1):
        node = child(node, index)
        if depth == 3:
            account = node
        scopes.append(dict(depth=depth, private=extended(node, dogecoin=False),
                           public=extended(node, False, False) if depth >= 3 else None))
    addresses = [dict(change=c, index=i, **address(child(child(account, c), i)[0]))
                 for c in [0, 1] for i in range(40)]
    source = f'https://raw.githubusercontent.com/bitcoin-cash-node/bitcoin-cash-node/{CORE}/src/test/data/key_io_valid.json'
    core = json.load(urllib.request.urlopen(source, timeout=15))
    wifs = [dict(wif=wif, hex=key[:64], compressed=meta['isCompressed'], testnet=meta['chain'] != 'main',
                 **address(int(key[:64], 16), meta['isCompressed']))
            for wif, key, meta in core if meta['isPrivkey']]
    result = dict(source=source, seed=seed.hex(), root=extended(root, dogecoin=False),
                  scopes=scopes, addresses=addresses, wifs=wifs)
    folder = Path(__file__).resolve().parents[1] / 'Packages/OathBitcoin/Tests/OathBitcoinTests/Fixtures'
    (folder / 'bitcoincash-vectors.json').write_text(json.dumps(result, indent=2) + '\n')
    for kind in ['valid', 'invalid']:
        url = f'https://raw.githubusercontent.com/bitjson/cashtokens/{TOKENS}/test-vectors/token-prefix-{kind}.json'
        data = urllib.request.urlopen(url, timeout=15).read()
        (folder / f'bitcoincash-tokens-{kind}.json').write_bytes(data)
    print(f'Generated {len(addresses)} BCH address/script/hash cases, {len(scopes)} key scopes and {len(wifs)} BCHN WIF cases.')


if __name__ == '__main__':
    main()

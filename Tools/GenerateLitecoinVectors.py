#!/usr/bin/env python3
"""Public BIP39/Litecoin Core fixtures, independent of BDK and WalletCore.

Uses Python cryptography/OpenSSL for secp256k1 and a small BIP32 reference.
Never reads installed wallets. All keys are published test material, not funds.
"""
import hashlib
import hmac
import json
import urllib.request
from pathlib import Path
from GenerateDogecoinVectors import ORDER, base58check, public_key, hash160, child

CORE_REVISION = "ec1b6489a900d09cf5991e220dce089c77a232a2"
VERSIONS = {
    "xprv": 0x0488ADE4, "xpub": 0x0488B21E, "yprv": 0x049D7878,
    "ypub": 0x049D7CB2, "zprv": 0x04B2430C, "zpub": 0x04B24746,
    "Ltpv": 0x019D9CFE, "Ltub": 0x019DA462, "Mtpv": 0x01B26792, "Mtub": 0x01B26EF6,
}


def extended(node, prefix):
    scalar, chain_code, depth, fingerprint, index = node
    secret = prefix.endswith("prv") or prefix.endswith("pv")
    key = b"\0" + scalar.to_bytes(32, "big") if secret else public_key(scalar)
    return base58check(VERSIONS[prefix].to_bytes(4, "big") + bytes([depth]) + fingerprint
                       + index.to_bytes(4, "big") + chain_code + key)


def witness_address(version, program):
    # Convert using a bit string, deliberately different from the Swift encoder.
    bits = ''.join(f'{byte:08b}' for byte in program)
    bits += '0' * (-len(bits) % 5)
    values = [version] + [int(bits[i:i+5], 2) for i in range(0, len(bits), 5)]
    hrp = 'ltc'
    expanded = [ord(c) >> 5 for c in hrp] + [0] + [ord(c) & 31 for c in hrp]
    generators = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
    chk = 1
    for value in expanded + values + [0] * 6:
        top = chk >> 25
        chk = ((chk & 0x1ffffff) << 5) ^ value
        for i, generator in enumerate(generators):
            if (top >> i) & 1:
                chk ^= generator
    chk ^= 1 if version == 0 else 0x2bc830a3
    values += [(chk >> (5 * (5 - i))) & 31 for i in range(6)]
    return hrp + '1' + ''.join('qpzry9x8gf2tvdw0s3jn54khce6mua7l'[v] for v in values)


def address(scalar, purpose, compressed=True):
    digest = hash160(public_key(scalar, compressed))
    if purpose == 44:
        script = b'\x76\xa9\x14' + digest + b'\x88\xac'
        encoded = base58check(bytes([48]) + digest)
    elif purpose == 49:
        script_hash = hash160(b'\0\x14' + digest)
        script = b'\xa9\x14' + script_hash + b'\x87'
        encoded = base58check(bytes([50]) + script_hash)
    elif purpose == 84:
        script = b'\0\x14' + digest
        encoded = witness_address(0, digest)
    else:
        public = public_key(scalar)
        even_scalar = scalar if public[0] == 2 else ORDER - scalar
        tag = hashlib.sha256(b'TapTweak').digest()
        tweak = int.from_bytes(hashlib.sha256(tag + tag + public[1:]).digest(), 'big')
        assert tweak < ORDER
        output_key = public_key((even_scalar + tweak) % ORDER)[1:]
        script = b'\x51\x20' + output_key
        encoded = witness_address(1, output_key)
    return {'address': encoded, 'script': script.hex(), 'scriptHash': hashlib.sha256(script).digest()[::-1].hex()}


def main():
    words = ' '.join(['abandon'] * 11 + ['about'])
    seed = hashlib.pbkdf2_hmac('sha512', words.encode(), b'mnemonic', 2048)
    digest = hmac.new(b'Bitcoin seed', seed, hashlib.sha512).digest()
    root = int.from_bytes(digest[:32], 'big'), digest[32:], 0, bytes(4), 0
    addresses, scopes = [], []
    for purpose in [86, 84, 49, 44]:
        purpose_node = child(root, purpose + 2**31)
        coin_node = child(purpose_node, 2 + 2**31)
        account = child(coin_node, 2**31)
        branch = child(account, 0)
        leaf = child(branch, 0)
        for depth, node in [(1, purpose_node), (2, coin_node), (3, account), (4, branch), (5, leaf)]:
            scopes.append({'purpose': purpose, 'depth': depth,
                           'keys': {p: extended(node, p) for p in VERSIONS if depth >= 3 or p.endswith(('prv', 'pv'))}})
        for change in [0, 1]:
            for index in range(40):
                scalar = child(child(account, change), index)[0]
                addresses.append({'purpose': purpose, 'change': change, 'index': index, **address(scalar, purpose)})
    source = f'https://raw.githubusercontent.com/litecoin-project/litecoin/{CORE_REVISION}/src/test/data/key_io_valid.json'
    with urllib.request.urlopen(source, timeout=15) as response:
        core = json.load(response)
    wifs = []
    for wif, key_hex, metadata in core:
        if not metadata['isPrivkey']:
            continue
        key_hex = key_hex[:64]
        scalar = int(key_hex, 16)
        wifs.append({'wif': wif, 'hex': key_hex, 'compressed': metadata['isCompressed'],
                     'testnet': metadata['chain'] != 'main', 'address': address(scalar, 44, metadata['isCompressed'])['address']})
    other = (root[0], hashlib.sha256(root[1]).digest(), *root[2:])
    data = {'source': source, 'seed': seed.hex(), 'root': extended(root, 'Ltpv'),
            'rootXprv': extended(root, 'xprv'), 'otherRoot': extended(other, 'Ltpv'),
            'otherRootXprv': extended(other, 'xprv'), 'roots': {p: extended(root, p) for p in VERSIONS if p.endswith(('prv', 'pv'))},
            'scopes': scopes, 'addresses': addresses, 'wifs': wifs}
    destination = Path(__file__).resolve().parents[1] / 'Packages/OathBitcoin/Tests/OathBitcoinTests/Fixtures/litecoin-vectors.json'
    destination.write_text(json.dumps(data, indent=2) + '\n')
    print(f'Generated {len(addresses)} Litecoin address/script/hash vectors, {len(scopes)} key scopes, {len(wifs)} Core WIF fixtures.')


if __name__ == '__main__':
    main()

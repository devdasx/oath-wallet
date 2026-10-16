#!/usr/bin/env python3
"""Reproduce public Dogecoin test vectors independently of BDK/WalletCore.

Requires Python cryptography (OpenSSL secp256k1). Reads only a pinned public
Dogecoin Core fixture; never reads installed wallets or user key material.
"""
import hashlib
import hmac
import json
import urllib.request
from pathlib import Path

from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

ORDER = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
CORE_REVISION = "47a303a449999314abcf83bd1fc7e77dd4540fcd"


def base58check(payload):
    data = payload + hashlib.sha256(hashlib.sha256(payload).digest()).digest()[:4]
    value, encoded = int.from_bytes(data, "big"), ""
    while value:
        encoded = ALPHABET[value % 58] + encoded
        value //= 58
    return "1" * (len(data) - len(data.lstrip(b"\0"))) + encoded


def public_key(scalar, compressed=True):
    return ec.derive_private_key(scalar, ec.SECP256K1()).public_key().public_bytes(
        Encoding.X962, PublicFormat.CompressedPoint if compressed else PublicFormat.UncompressedPoint
    )


def hash160(data):
    return hashlib.new("ripemd160", hashlib.sha256(data).digest()).digest()


def address(scalar, compressed=True):
    return base58check(b"\x1e" + hash160(public_key(scalar, compressed)))


def child(node, index):
    scalar, chain_code, depth, _, _ = node
    payload = b"\0" + scalar.to_bytes(32, "big") if index >= 2**31 else public_key(scalar)
    digest = hmac.new(chain_code, payload + index.to_bytes(4, "big"), hashlib.sha512).digest()
    tweak = int.from_bytes(digest[:32], "big")
    derived = (tweak + scalar) % ORDER
    assert tweak < ORDER and derived != 0  # No invalid children in this public fixture.
    return derived, digest[32:], depth + 1, hash160(public_key(scalar))[:4], index


def extended(node, secret=True, dogecoin=True):
    scalar, chain_code, depth, fingerprint, index = node
    version = (0x02FAC398 if secret else 0x02FACAFD) if dogecoin else (0x0488ADE4 if secret else 0x0488B21E)
    key = b"\0" + scalar.to_bytes(32, "big") if secret else public_key(scalar)
    return base58check(version.to_bytes(4, "big") + bytes([depth]) + fingerprint + index.to_bytes(4, "big") + chain_code + key)


def main():
    words = " ".join(["abandon"] * 11 + ["about"])
    seed = hashlib.pbkdf2_hmac("sha512", words.encode(), b"mnemonic", 2048)
    digest = hmac.new(b"Bitcoin seed", seed, hashlib.sha512).digest()
    root = int.from_bytes(digest[:32], "big"), digest[32:], 0, bytes(4), 0
    account = root
    for index in [44 + 2**31, 3 + 2**31, 2**31]:
        account = child(account, index)
    addresses = []
    for change in [0, 1]:
        branch = child(account, change)
        for index in range(40):
            addresses.append({"change": change, "index": index, "address": address(child(branch, index)[0])})

    source = f"https://raw.githubusercontent.com/dogecoin/dogecoin/{CORE_REVISION}/src/test/data/base58_keys_valid.json"
    with urllib.request.urlopen(source, timeout=12) as response:
        core = json.load(response)
    wifs = []
    for wif, scalar_hex, metadata in core:
        if metadata["isPrivkey"]:
            # Core ParseHex ignores the odd trailing nibble in its compressed
            # fixtures. The private scalar is the first 32 bytes.
            scalar_hex = scalar_hex[:64]
            scalar = int(scalar_hex, 16)
            wifs.append({"wif": wif, "hex": scalar_hex, "compressed": metadata["isCompressed"],
                         "testnet": metadata["isTestnet"],
                         "address": address(scalar, metadata["isCompressed"]) if 0 < scalar < ORDER else ""})
    scopes = []
    for path in [[], [44 + 2**31], [44 + 2**31, 3 + 2**31],
                 [44 + 2**31, 3 + 2**31, 2**31],
                 [44 + 2**31, 3 + 2**31, 2**31, 0],
                 [44 + 2**31, 3 + 2**31, 2**31, 1],
                 [44 + 2**31, 3 + 2**31, 2**31, 0, 7],
                 [44 + 2**31, 3 + 2**31, 2**31, 1, 7]]:
        node = root
        for index in path:
            node = child(node, index)
        scopes.append({"depth": len(path), "dogecoin": extended(node), "bitcoin": extended(node, dogecoin=False)})
    data = {
        "source": "BIP39 public abandon/about vector; independent Python cryptography secp256k1/BIP32 reference; WIF fixtures from Dogecoin Core src/test/data/base58_keys_valid.json",
        "seed": seed.hex(), "root": extended(root), "rootXprv": extended(root, dogecoin=False),
        "otherRoot": extended((root[0], hashlib.sha256(root[1]).digest(), *root[2:])),
        "otherRootXprv": extended((root[0], hashlib.sha256(root[1]).digest(), *root[2:]), dogecoin=False),
        "accountPrivate": extended(account), "accountPublic": extended(account, False),
        "accountXprv": extended(account, dogecoin=False), "accountXpub": extended(account, False, False),
        "addresses": addresses, "wifs": wifs, "scopes": scopes,
    }
    destination = Path(__file__).resolve().parents[1] / "Packages/OathBitcoin/Tests/OathBitcoinTests/Fixtures/dogecoin-vectors.json"
    destination.write_text(json.dumps(data, indent=2) + "\n")
    print(f"Generated {len(addresses)} public addresses and {len(wifs)} WIF cases")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Independent public BIP39/SLIP-0010 fixtures; prints addresses only.

No app storage, network access, or real user material is read. Requires the
cryptography Python package, also used by the UTXO fixture generators.
"""
import hashlib
import hmac
import struct
import unicodedata
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

PHRASE = "abandon " * 11 + "about"
ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


def address(path, passphrase):
    seed = hashlib.pbkdf2_hmac("sha512", unicodedata.normalize("NFKD", PHRASE).encode(),
                              ("mnemonic" + unicodedata.normalize("NFKD", passphrase)).encode(), 2048)
    node = hmac.digest(b"ed25519 seed", seed, "sha512")
    for part in path.split("/")[1:]:
        assert part.endswith("'")
        node = hmac.digest(node[32:], b"\0" + node[:32] + struct.pack(">I", int(part[:-1]) + 2**31), "sha512")
    public = Ed25519PrivateKey.from_private_bytes(node[:32]).public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    integer, text = int.from_bytes(public, "big"), ""
    while integer:
        integer, digit = divmod(integer, 58)
        text = ALPHABET[digit] + text
    return "1" * (len(public) - len(public.lstrip(b"\0"))) + text


if __name__ == "__main__":
    for password in ["", "TREZOR"]:
        for index in [0, 1, 7]:
            for suffix in ["/0'", ""]:
                path = f"m/44'/501'/{index}'" + suffix
                print("BIP39 passphrase fixture" if password else "Base fixture", path, address(path, password))

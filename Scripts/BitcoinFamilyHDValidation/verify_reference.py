#!/usr/bin/env python3
"""Independent bip-utils/libsecp256k1 verification of production Swift outputs.

Install bip-utils==2.12.1 in an isolated Python environment, then run this after
prepare.py. This performs no broadcasts and uses only the public BIP39 vector.
"""
import hashlib, json, pathlib, struct, tempfile
from bip_utils import Bip39SeedGenerator, Bip44, Bip44Coins, Bip49, Bip49Coins, Bip84, Bip84Coins, Bip44Changes
from coincurve import PublicKey

CACHE = pathlib.Path(tempfile.gettempdir()) / 'aperture-family-hd'
MNEMONIC = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about'
SEED = Bip39SeedGenerator(MNEMONIC).Generate()

def dsha(data):
    return hashlib.sha256(hashlib.sha256(data).digest()).digest()

def hash160(data):
    return hashlib.new('ripemd160', hashlib.sha256(data).digest()).digest()

def reference(chain, path):
    parts = path.split('/')
    purpose = int(parts[1][:-1])
    cls, coin = {
        ('dogecoin', 44): (Bip44, Bip44Coins.DOGECOIN),
        ('bitcoin_cash', 44): (Bip44, Bip44Coins.BITCOIN_CASH),
        ('litecoin', 44): (Bip44, Bip44Coins.LITECOIN),
        ('litecoin', 49): (Bip49, Bip49Coins.LITECOIN),
        ('litecoin', 84): (Bip84, Bip84Coins.LITECOIN),
    }[(chain, purpose)]
    context = cls.FromSeed(SEED, coin).Purpose().Coin().Account(0).Change(Bip44Changes(int(parts[4]))).AddressIndex(int(parts[5]))
    pub = context.PublicKey().RawCompressed().ToBytes()
    pkh = hash160(pub)
    script = b'\x00\x14' + pkh if purpose == 84 else (
        b'\xa9\x14' + hash160(b'\x00\x14' + pkh) + b'\x87' if purpose == 49 else b'\x76\xa9\x14' + pkh + b'\x88\xac')
    return context.PublicKey().ToAddress(), pub, script

vectors = json.loads((CACHE / 'derived-vectors.json').read_text())
for vector in vectors:
    address, public, script = reference(vector['chain'], vector['path'])
    assert address == vector['address'], (vector['path'], address, vector['address'])
    assert public.hex() == vector['publicKey']
    assert script.hex() == vector['script']
print(f'PASS: {len(vectors)} addresses, public keys and locking scripts match independent BIP44/49/84 derivation.')

def varint(n):
    if n < 253: return bytes([n])
    if n <= 65535: return b'\xfd' + struct.pack('<H', n)
    if n <= 4294967295: return b'\xfe' + struct.pack('<I', n)
    return b'\xff' + struct.pack('<Q', n)

class Reader:
    def __init__(self, data): self.data, self.p = data, 0
    def take(self, n):
        result = self.data[self.p:self.p+n]
        assert len(result) == n
        self.p += n
        return result
    def integer(self, n): return int.from_bytes(self.take(n), 'little')
    def size(self):
        n = self.integer(1)
        return n if n < 253 else self.integer({253: 2, 254: 4, 255: 8}[n])
    def blob(self): return self.take(self.size())

def serialize(version, ins, outs, locktime, signing_index=None, previous_script=None):
    result = version + varint(len(ins))
    for i, item in enumerate(ins):
        script = item['script'] if signing_index is None else (previous_script if i == signing_index else b'')
        result += item['outpoint'] + varint(len(script)) + script + item['sequence']
    return result + varint(len(outs)) + b''.join(outs) + locktime

fixtures = json.loads((CACHE / 'signed-fixtures.json').read_text())
signature_count = 0
for fixture in fixtures:
    raw = bytes.fromhex(fixture['hex'])
    r = Reader(raw)
    version = r.take(4)
    witness = raw[4:6] == b'\x00\x01'
    if witness: r.take(2)
    inputs = []
    for _ in range(r.size()):
        outpoint = r.take(36)
        inputs.append({'outpoint': outpoint, 'id': outpoint[:32][::-1].hex() + ':' + str(int.from_bytes(outpoint[32:], 'little')),
                       'script': r.blob(), 'sequence': r.take(4), 'witness': []})
    outputs, output_values, output_scripts = [], [], []
    for _ in range(r.size()):
        value, script = r.take(8), r.blob()
        outputs.append(value + varint(len(script)) + script)
        output_values.append(int.from_bytes(value, 'little'))
        output_scripts.append(script)
    if witness:
        for item in inputs:
            item['witness'] = [r.blob() for _ in range(r.size())]
    locktime = r.take(4)
    assert r.p == len(raw)
    stripped = serialize(version, inputs, outputs, locktime)
    assert dsha(stripped)[::-1].hex() == fixture['txid']
    vsize = (len(stripped) * 3 + len(raw) + 3) // 4
    assert int(fixture['fee']) >= vsize * fixture['rate']
    coins = {value['outpoint']: value for value in fixture['inputs']}
    assert set(coins) == {item['id'] for item in inputs}
    assert sum(int(coin['value']) for coin in coins.values()) - sum(output_values) == int(fixture['fee'])
    chain = fixture['chain']
    coin_type, purpose = (2, 84) if chain == 'litecoin' else ((3, 44) if chain == 'dogecoin' else (145, 44))
    _, _, receiver_script = reference(chain, f"m/{purpose}'/{coin_type}'/0'/0/9")
    assert sum(value for value, script in zip(output_values, output_scripts) if script == receiver_script) == int(fixture['amount'])
    for index, item in enumerate(inputs):
        coin = coins[item['id']]
        previous_script = bytes.fromhex(coin['script'])
        if item['witness']:
            signature, pub = item['witness']
            if previous_script[:2] == b'\xa9\x14':
                redeem = b'\x00\x14' + hash160(pub)
                assert item['script'] == bytes([len(redeem)]) + redeem
                assert hash160(redeem) == previous_script[2:-1]
            else:
                assert item['script'] == b''
                assert previous_script == b'\x00\x14' + hash160(pub)
            script_code = b'\x76\xa9\x14' + hash160(pub) + b'\x88\xac'
        else:
            pushes = Reader(item['script'])
            signature, pub = pushes.blob(), pushes.blob()
            assert pushes.p == len(pushes.data)
            assert previous_script == b'\x76\xa9\x14' + hash160(pub) + b'\x88\xac'
            script_code = previous_script
        assert pub.hex() == coin['publicKey']
        sighash = signature[-1]
        assert sighash == (0x41 if chain == 'bitcoin_cash' else 0x01)
        if item['witness'] or chain == 'bitcoin_cash':
            preimage = (version + dsha(b''.join(i['outpoint'] for i in inputs)) + dsha(b''.join(i['sequence'] for i in inputs))
                + item['outpoint'] + varint(len(script_code)) + script_code + struct.pack('<Q', int(coin['value']))
                + item['sequence'] + dsha(b''.join(outputs)) + locktime + struct.pack('<I', sighash))
        else:
            preimage = serialize(version, inputs, outputs, locktime, index, previous_script) + struct.pack('<I', sighash)
        assert PublicKey(pub).verify(signature[:-1], dsha(preimage), hasher=None)
        signature_count += 1
print(f'PASS: {signature_count} independent ECDSA signature checks across {len(fixtures)} offline transactions, including mixed Litecoin and BCH ForkID.')

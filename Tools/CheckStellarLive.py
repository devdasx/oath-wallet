#!/usr/bin/env python3
"""Read-only public-account comparison: ANKR event index vs SDF Horizon.

Never derives keys, signs, submits transactions, or prints credentials.
The production Swift client/database have separate opt-in live tests.
"""
import base64
import argparse
import binascii
import concurrent.futures
from decimal import Decimal, getcontext
import hashlib
import json
import os
from pathlib import Path
import plistlib
import struct
import subprocess
import sys
import urllib.parse
import urllib.request

getcontext().prec = 80
ROOT = Path(__file__).resolve().parents[1]
OWNERS = [
    "GBEBCRCJ5VX7GERSGJ5XGJX7K2CHNVQB67K2KGCX7RFGMCBIIZQ5E4GY",
    "GA222Q73DNNRWT3JWCFVJOHVBRNR2T7VMK7T52ENAOTOUO4I347DLTWZ",
    "GA223H7O26KC7NWDEH6R4D5ITI35I4R7BH5VDLPFTSKMWH2RUZD474TJ",
]
NATIVE = "CAS3J7GYLGXMF6TDJBBYYSE3HQ6BBSMLNUQ34T6TZMYMW2EVH34XOWMA"
SDF = "https://horizon.stellar.org"
word = lambda n: struct.pack(">I", n)


def read(url, body=None):
    request = urllib.request.Request(url, None if body is None else json.dumps(body).encode(),
                                     {"Content-Type": "application/json", "User-Agent": "OathWallet/1.0"})
    with urllib.request.urlopen(request, timeout=45) as response:
        return json.load(response, parse_float=Decimal)


def strkey(data, version):
    payload = bytes([version]) + data
    return base64.b32encode(payload + struct.pack("<H", binascii.crc_hqx(payload, 0))).decode()


def contract(code, issuer):
    size = 4 if len(code) <= 4 else 12
    asset = word(1 if size == 4 else 2) + code.encode().ljust(size, b"\0") + word(0) + base64.b32decode(issuer)[1:33]
    network = hashlib.sha256(b"Public Global Stellar Network ; September 2015").digest()
    return strkey(hashlib.sha256(word(8) + network + word(1) + asset).digest(), 16)


def rpc(key, method, params):
    result = read("https://rpc.ankr.com/multichain/" + key,
                  {"jsonrpc": "2.0", "id": 1, "method": method,
                   "params": {"blockchain": "stellar_soroban", **params}})
    assert "error" not in result, "ANKR rejected the read-only request"
    return result["result"]


def records(path):
    cursor = None
    while True:
        query = {"limit": 200, "order": "asc"}
        if cursor:
            query["cursor"] = cursor
        rows = read(SDF + path + "?" + urllib.parse.urlencode(query))["_embedded"]["records"]
        if not rows:
            return
        yield from rows
        next_cursor = rows[-1]["paging_token"]
        assert cursor != next_cursor, "Repeated Horizon cursor"
        cursor = next_cursor


def sc_value(encoded):
    value = base64.b64decode(encoded, validate=True)
    tag = struct.unpack(">I", value[:4])[0]
    if tag in (14, 15):
        size = struct.unpack(">I", value[4:8])[0]
        return value[8:8 + size].decode()
    if tag == 10:
        return int.from_bytes(value[4:20], "big", signed=True)
    if tag == 17:
        present, size = struct.unpack(">II", value[4:12])
        assert present == 1 and size == 2
        offset, fields = 12, {}
        for _ in range(size):
            key_type, length = struct.unpack(">II", value[offset:offset + 8])
            assert key_type == 15
            key = value[offset + 8:offset + 8 + length].decode()
            offset += 8 + ((length + 3) // 4) * 4
            field_type = struct.unpack(">I", value[offset:offset + 4])[0]
            if field_type == 10:
                fields[key] = int.from_bytes(value[offset + 4:offset + 20], "big", signed=True)
                offset += 20
            elif field_type == 5:
                offset += 12
            elif field_type in (13, 14):
                length = struct.unpack(">I", value[offset + 4:offset + 8])[0]
                offset += 8 + ((length + 3) // 4) * 4
            else:
                raise AssertionError("Unsupported memo value")
        assert offset == len(value)
        return fields["amount"]
    if tag == 18:
        kind = struct.unpack(">I", value[4:8])[0]
        if kind == 0:
            return strkey(value[12:44], 48)
        if kind == 1:
            return strkey(value[8:40], 16)
        if kind == 2:
            return strkey(value[16:48], 48)
        if kind in (3, 4):
            return ("claimable:" if kind == 3 else "pool:") + value[8:].hex()
    raise AssertionError("Unexpected SCVal in comparison: tag=" + str(tag) + "; bytes=" + str(len(value)))


def compare_history(key, owner):
    txs = read(SDF + "/accounts/" + owner + "/transactions?order=desc&include_failed=true&limit=3")["_embedded"]["records"]
    assert txs, "Fixture account has no recent history"
    start, end = min(x["ledger"] for x in txs), max(x["ledger"] for x in txs)
    topic = base64.b64encode(word(18) + word(0) + word(0) + base64.b32decode(owner)[1:33]).decode()
    cursor, events = None, []
    while True:
        params = {"startLedger": start, "endLedger": end + 1, "limit": 200,
                  "filters": [{"type": "contract", "topics": [["*", topic, "**"], ["*", "*", topic, "**"]]}]}
        if cursor:
            params["cursor"] = cursor
        result = rpc(key, "stellar_getEvents", params)
        page = result["events"]
        if not page:
            break
        assert all(start <= x["ledger"] <= end for x in page)
        next_cursor = page[-1]["pagingToken"]
        assert next_cursor != cursor, "Repeated ANKR cursor"
        cursor = next_cursor
        events.extend(page)
    checked = 0
    for tx in txs:
        hashes = {tx["hash"], tx.get("inner_transaction", {}).get("hash")}
        expected, actual = {}, {}
        for effect in records("/transactions/" + tx["hash"] + "/effects"):
            if effect["account"] != owner or effect["type"] not in ("account_credited", "account_debited"):
                continue
            ref = NATIVE if effect["asset_type"] == "native" else contract(effect["asset_code"], effect["asset_issuer"])
            amount = Decimal(effect["amount"]) * 10**7
            assert amount == int(amount)
            expected[ref] = expected.get(ref, 0) + int(amount) * (1 if effect["type"] == "account_credited" else -1)
        for event in events:
            if event["txHash"] not in hashes or not event["inSuccessfulContractCall"]:
                continue
            kind, ref = sc_value(event["topic"][0]), event["contractId"]
            if kind not in ("fee", "transfer", "mint", "burn", "clawback"):
                continue
            topics = [kind] + [sc_value(x) for x in event["topic"][1:3 if kind == "transfer" else 2]]
            if kind == "fee":
                continue
            amount = sc_value(event["value"])
            if kind == "transfer":
                delta = amount * (int(topics[2] == owner) - int(topics[1] == owner))
            elif kind in ("mint", "burn", "clawback"):
                assert topics[1] == owner
                delta = amount * (1 if kind == "mint" else -1)
            else:
                continue
            actual[ref] = actual.get(ref, 0) + delta
        expected = {k: v for k, v in expected.items() if v}
        actual = {k: v for k, v in actual.items() if v}
        assert expected == actual, "Transaction transfer amounts differ from independent Horizon effects"
        checked += 1
    print(f"History {owner[:8]}…: {checked} transactions, {len(events)} events; exact amounts match SDF Horizon")
    return checked


def compare_contract_balance(key):
    owner = "GAKL6IWNAFDFETXPIHBNOUVD5LSZFFPFHPCN3XLATIKGFJOMIF5R7JYV"
    ref = "CAS3FL6TLZKDGGSISDBWGGPXT3NRR4DYTZD7YOD3HMYO6LTJUVGRVEAM"
    result = rpc(key, "stellar_getAccountBalance", {"walletAddress": owner, "onlyWhitelisted": False, "pageSize": 100})
    assets = result["assets"]
    while result.get("nextPageToken"):
        result = rpc(key, "stellar_getAccountBalance", {"walletAddress": owner, "onlyWhitelisted": False,
                     "pageSize": 100, "pageToken": result["nextPageToken"]})
        assets.extend(result["assets"])
    indexed = next(x for x in assets if x["contractAddress"] == ref)
    # Read-only SEP-41 balance(Address) simulation. No signatures, submission,
    # authorization entries, secret key, or user wallet is involved.
    function = b"balance"
    envelope = word(2) + word(0) + base64.b32decode(owner)[1:33]
    envelope += word(100) + b"\0" * 8 + word(0) + word(0) + word(1) + word(0) + word(24) + word(0)
    envelope += word(1) + base64.b32decode(ref)[1:33] + word(len(function)) + function + b"\0"
    envelope += word(1) + word(18) + word(0) + word(0) + base64.b32decode(owner)[1:33]
    envelope += word(0) + word(0) + word(0)
    reply = read("https://rpc.ankr.com/stellar_soroban/" + key,
                 {"jsonrpc": "2.0", "id": 1, "method": "simulateTransaction",
                  "params": {"transaction": base64.b64encode(envelope).decode()}})
    assert "error" not in reply and "error" not in reply["result"], "Contract read simulation failed"
    actual = sc_value(reply["result"]["results"][0]["xdr"])
    assert actual == int(indexed["balanceRawInteger"]), "Contract token balance differs from on-chain read"
    print("Contract-only Comet token: exact indexed balance matches read-only on-chain balance()")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true", help="Enable read-only public mainnet checks")
    parser.add_argument("--swift", action="store_true", help="Also run production Swift client/database live tests on the host")
    args = parser.parse_args()
    if not args.run:
        parser.print_help()
        return
    with (ROOT / "OathApp/Private/TokenRPC.plist").open("rb") as source:
        key = plistlib.load(source)["AnkrAPIKey"]
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        results = list(pool.map(lambda owner: compare_history(key, owner), OWNERS))
    compare_contract_balance(key)
    print(f"PASS: {sum(results)} public Stellar transaction comparisons; no signing or broadcast")
    if args.swift:
        env = os.environ.copy()
        env["OATH_STELLAR_LIVE_KEY"] = key
        env["OATH_STELLAR_DATABASE_KEY"] = key
        def run(job):
            package, scratch, test_filter = job
            result = subprocess.run(["swift", "test", "--package-path", str(ROOT / "Packages" / package),
                "--scratch-path", scratch, "--build-system", "native", "--filter", test_filter],
                env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            print(result.stdout.replace(key, "[redacted]"), end="")
            return result.returncode
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            codes = list(pool.map(run, [
                ("OathAnkr", "/tmp/oath-solana-ankr-build", "StellarTests/testLive"),
                ("OathDatabase", "/tmp/oath-token-database-build", "StellarLedgerTests/testLive")]))
        if any(codes):
            sys.exit(1)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # Network errors may include credential-bearing URLs. Never print them.
        print("FAIL:", type(error).__name__)
        if isinstance(error, AssertionError):
            print(str(error))
        sys.exit(1)

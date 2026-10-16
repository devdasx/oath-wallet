#!/usr/bin/env python3
"""Read-only HTTPS fee probes. No wallets, credentials, signed bytes or TCP RPC.
Respect API denials: stop using a host on 403/429/430, do not rotate identities.
Use the opt-in Swift tests to validate the actual app decoders and cache.
"""
import argparse
import json
import time
import urllib.error
import urllib.parse
import urllib.request

HTTP = {
    "btc_mempool": "https://mempool.space/api/v1/fees/recommended",
    "btc_blockstream": "https://blockstream.info/api/fee-estimates",
    "btc_blockcypher": "https://api.blockcypher.com/v1/btc/main",
    "ltc_space": "https://litecoinspace.org/api/v1/fees/recommended",
    "ltc_blockcypher": "https://api.blockcypher.com/v1/ltc/main",
    "doge_blockcypher": "https://api.blockcypher.com/v1/doge/main",
}
for chain in ["bitcoin", "bitcoin-cash", "litecoin", "dogecoin"]:
    HTTP[chain + "_blockchair"] = "https://api.blockchair.com/" + chain + "/stats"
for chain in ["bch", "ltc", "doge"]:
    HTTP[chain + "_blockbook"] = "https://" + chain + "1.trezor.io/api/v2/estimatefee/3"

blocked = set()
last_request = {}

def probe(name):
    host = urllib.parse.urlsplit(HTTP[name]).hostname
    if host in blocked:
        return {"source": name, "ok": False, "skipped": "provider cooldown"}
    # A shared public API has limits across chains, not just per endpoint.
    time.sleep(max(0, last_request.get(host, 0) + 1.2 - time.monotonic()))
    last_request[host] = time.monotonic()
    started = time.monotonic()
    result = {"source": name}
    try:
        req = urllib.request.Request(HTTP[name], headers={"Accept": "application/json"})
        with urllib.request.urlopen(req, timeout=3) as response:
            raw = response.read(65537)
        if len(raw) > 65536:
            raise ValueError("oversized response")
        body = json.loads(raw)
        code = body.get("context", {}).get("code", 200)
        if code in (403, 429, 430):
            blocked.add(host)
            return dict(result, ok=False, status=code)
        result["fee"] = {k: v for k, v in body.items() if "fee" in k.lower() or k in ("1", "2", "3", "name", "time", "result")}
        if "suggested_transaction_fee_per_byte_sat" in body.get("data", {}):
            result["fee"] = {"suggested_transaction_fee_per_byte_sat": body["data"]["suggested_transaction_fee_per_byte_sat"]}
        result["ok"] = bool(result["fee"])
    except urllib.error.HTTPError as error:
        if error.code in (403, 429, 430):
            blocked.add(host)
        result.update(ok=False, status=error.code)
    except Exception as error:
        result.update(ok=False, error=type(error).__name__)
    result["ms"] = round((time.monotonic() - started) * 1000)
    return result

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rounds", type=int, choices=range(1, 4), default=1)
    parser.add_argument("--source", choices=list(HTTP), action="append")
    args = parser.parse_args()
    for iteration in range(args.rounds):
        for name in args.source or HTTP:
            print(json.dumps(dict(round=iteration + 1, **probe(name))), flush=True)

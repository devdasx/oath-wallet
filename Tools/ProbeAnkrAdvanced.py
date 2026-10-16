#!/usr/bin/env python3
"""Read-only Advanced API research with public fixtures; never prints credentials.

Uses the existing ignored local RPC configuration. Responses contain public
chain data only and are saved outside the repository for schema inspection.
"""
import concurrent.futures
import json
import os
from pathlib import Path
import plistlib
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
CHAINS = "arbitrum avalanche base bsc eth fantom flare gnosis linea optimism polygon scroll somnia_mainnet story_mainnet taiko telos xlayer".split()
PUBLIC = ["0xF977814e90dA44bFA03b6295A0616a897441aceC", "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045", "0x0000000000000000000000000000000000000001"]

def run():
    key = os.environ.get("OATH_ANKR_API_KEY")
    if not key:
        with (ROOT / "OathApp/Private/TokenRPC.plist").open("rb") as f:
            key = plistlib.load(f).get("AnkrAPIKey")
    if not key:
        raise SystemExit("Local Ankr configuration missing")
    output = Path("/tmp/oath-ankr-research/responses")
    output.mkdir(parents=True, exist_ok=True)
    jobs = [("stats", "ankr_getBlockchainStats", {})]
    for chain in CHAINS:
        for method, field in [("ankr_getAccountBalance", "walletAddress"), ("ankr_getTransactionsByAddress", "address"), ("ankr_getTokenTransfers", "address")]:
            address = PUBLIC[0]
            params = {"blockchain": [chain], field: [address] if method.endswith("Transfers") else address, "pageSize": 3}
            if method.endswith("Balance"): params["onlyWhitelisted"] = True
            else: params["descOrder"] = True
            if method.endswith("ByAddress"): params.update(includeLogs=True, decodeLogs=True, decodeTxData=True)
            jobs.append((chain + "-" + method, method, params))
    for i, address in enumerate(PUBLIC[1:]):
        jobs.append(("multi-" + str(i), "ankr_getAccountBalance", {"blockchain": CHAINS, "walletAddress": address, "onlyWhitelisted": True, "pageSize": 5}))

    def request(job):
        name, method, params = job
        body = json.dumps(dict(jsonrpc="2.0", id=1, method=method, params=params)).encode()
        try:
            req = urllib.request.Request("https://rpc.ankr.com/multichain/" + key, data=body, headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=35) as response:
                raw = response.read(64 * 1024 * 1024 + 1)
                if len(raw) > 64 * 1024 * 1024:
                    return {"case": name, "errorType": "ResponseTooLarge"}
            data = json.loads(raw)
            (output / (name + ".json")).write_bytes(raw)
            result = data.get("result", {})
            arrays = {k: len(v) for k,v in result.items() if isinstance(v,list)} if isinstance(result,dict) else {}
            # Provider messages may echo a URL. Keep diagnostics numeric so a
            # credential-bearing endpoint can never reach console output.
            error = data.get("error")
            return {"case": name, "rpcErrorCode": error.get("code") if isinstance(error,dict) else None, "fields": list(result) if isinstance(result,dict) else type(result).__name__, "counts": arrays, "next": bool(result.get("nextPageToken")) if isinstance(result,dict) else False}
        except Exception as e:
            return {"case":name, "errorType":type(e).__name__}
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
        for result in executor.map(request, jobs):
            print(json.dumps(result), flush=True)

if __name__ == "__main__": run()

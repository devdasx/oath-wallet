#!/usr/bin/env python3
"""Live, read-only ANKR TRON mainnet contract tests.

Requires ANKR_API_KEY in the invoking process. No private wallet material is
used and the key is never read from or copied into the application bundle.
"""

import hashlib
import json
import os
import urllib.error
import urllib.request

USDT = "0xa614f803b6fd780986a42c78ec9c7f77e6ded13c"
TRANSFER_TOPIC = (
    "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
)


def api_key() -> str:
    value = os.environ.get("ANKR_API_KEY")
    if not value:
        raise RuntimeError("ANKR_API_KEY is unavailable")
    return value


def rpc(method: str, params: list, request_id: int = 1) -> dict:
    endpoint = f"https://rpc.ankr.com/tron_jsonrpc/{api_key()}"
    body = json.dumps(
        {"jsonrpc": "2.0", "method": method, "params": params, "id": request_id}
    ).encode()
    request = urllib.request.Request(
        endpoint, data=body, headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        payload = json.load(response)
    if "error" in payload:
        raise RuntimeError(payload["error"])
    return payload


def base58check(hex_address: str) -> str:
    alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    value = bytes.fromhex(hex_address)
    payload = value + hashlib.sha256(hashlib.sha256(value).digest()).digest()[:4]
    number = int.from_bytes(payload, "big")
    result = ""
    while number:
        number, remainder = divmod(number, 58)
        result = alphabet[remainder] + result
    return result


def main() -> None:
    block = int(rpc("eth_blockNumber", [])["result"], 16)
    assert block > 0

    known_account = "41c2ad4ef36bf52f1a724783c822b3a8dd68ae7e00"
    trx_balance = int(
        rpc("eth_getBalance", [known_account, "latest"])["result"], 16
    )
    assert trx_balance >= 0

    logs = rpc(
        "eth_getLogs",
        [
            {
                "address": USDT,
                "fromBlock": hex(block - 5),
                "toBlock": "latest",
                "topics": [TRANSFER_TOPIC],
            }
        ],
    )["result"]
    assert logs
    owner = logs[0]["topics"][2][-40:]
    call_data = "0x70a08231" + owner.rjust(64, "0")
    usdt_balance = int(
        rpc(
            "eth_call",
            [{"to": USDT, "data": call_data}, "latest"],
        )["result"],
        16,
    )
    assert usdt_balance >= 0

    address = base58check("41" + owner)
    history_url = (
        f"https://api.trongrid.io/v1/accounts/{address}/transactions/trc20"
        "?only_confirmed=true&limit=5"
    )
    with urllib.request.urlopen(history_url, timeout=30) as response:
        history = json.load(response)
    assert history.get("success") is True
    assert history.get("data")

    try:
        rpc("eth_getBalance", ["not-an-address", "latest"])
    except RuntimeError:
        pass
    else:
        raise AssertionError("Malformed address was unexpectedly accepted")

    print(
        json.dumps(
            {
                "block": block,
                "nativeBalanceValidated": True,
                "usdtTransferLogs": len(logs),
                "usdtBalanceValidated": True,
                "trc20HistoryValidated": True,
                "malformedAddressRejected": True,
            }
        )
    )


if __name__ == "__main__":
    main()

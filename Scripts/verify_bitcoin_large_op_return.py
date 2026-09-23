#!/usr/bin/env python3
"""Read-only mainnet check of the confirmed large OP_RETURN example.

Uses the app's existing mempool.space API. Never constructs, signs, or broadcasts
a transaction, and never prints message contents or wallet credentials.
"""

import json
import urllib.request


TRANSACTION_ID = "997518c0b946eeac48724bf7090a910d872f84cdc46b555d59ec487f8ab2cc36"


def decode_payload(script):
    if len(script) < 2 or script[0] != 0x6A:
        raise ValueError("Expected OP_RETURN followed by a data push")
    opcode = script[1]
    if opcode <= 75:
        offset, length = 2, opcode
    else:
        length_bytes = {0x4C: 1, 0x4D: 2, 0x4E: 4}.get(opcode)
        if length_bytes is None or len(script) < 2 + length_bytes:
            raise ValueError("Invalid push opcode or truncated length")
        offset = 2 + length_bytes
        length = int.from_bytes(script[2:offset], "little")
        if length < {1: 76, 2: 256, 4: 65536}[length_bytes]:
            raise ValueError("Non-minimal push encoding")
    if len(script) != offset + length:
        raise ValueError("Truncated data or trailing script bytes")
    return script[offset:]


def main():
    url = f"https://mempool.space/api/tx/{TRANSACTION_ID}"
    with urllib.request.urlopen(url, timeout=30) as response:
        transaction = json.load(response)
    assert transaction["txid"] == TRANSACTION_ID
    assert transaction["status"]["confirmed"] is True
    outputs = [output for output in transaction["vout"]
               if output["scriptpubkey"].startswith("6a")]
    assert len(outputs) == 1
    output = outputs[0]
    assert type(output["value"]) is int and output["value"] == 0
    script = bytes.fromhex(output["scriptpubkey"])
    payload = decode_payload(script)
    assert len(payload) == 1131 and len(script) == 1135
    assert type(transaction["weight"]) is int and transaction["weight"] == 5145
    assert transaction["size"] == 1368 and transaction["fee"] == 1290
    print(json.dumps({
        "transaction_id": TRANSACTION_ID,
        "confirmed": True,
        "payload_bytes": len(payload),
        "script_bytes": len(script),
        "transaction_weight": transaction["weight"],
        "virtual_bytes": (transaction["weight"] + 3) // 4,
        "fee_satoshis": transaction["fee"],
    }, indent=2))


if __name__ == "__main__":
    main()

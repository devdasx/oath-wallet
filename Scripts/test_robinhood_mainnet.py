#!/usr/bin/env python3
"""Read-only Robinhood mainnet preflight; never signs or sends transactions.

Run: python3 Scripts/test_robinhood_mainnet.py -v
Optionally set ROBINHOOD_ANKR_KEY_FILE to check the proposed ANKR integration.
A failing ANKR test means full app integration must remain disabled.
Only the key-file path is accepted, never a key in command-line arguments.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import unittest
import urllib.error
import urllib.request

RPC = "https://rpc.mainnet.chain.robinhood.com"
PUBLIC_NODE = "https://robinhood-rpc.publicnode.com"
CHAIN_ID = 4663
OWNER = "0x364c07cdd42733aac9a783a89c48df48fba38148"
TRANSACTION = "0x625943fed76ba835bf7384d3338dd0e4fb7cc75620521e3b6a78cd0e29454d1d"
BLOCK = "0x39f7063"
TRANSFER = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
USDG = "0x5fc5360d0400a0fd4f2af552add042d716f1d168"
WETH = "0x0bd7d308f8e1639fab988df18a8011f41eacad73"
HEADERS = {
    "Content-Type": "application/json",
    "Accept": "application/json",
    "User-Agent": "ApertureIntegrationVerification/1.0",
}


class ProviderFailure(Exception):
    """Contains only a status/code; never an endpoint with credentials."""


def fetch_json(url: str, payload=None):
    request = urllib.request.Request(
        url,
        data=None if payload is None else json.dumps(payload).encode(),
        headers=HEADERS,
    )
    try:
        with urllib.request.urlopen(request, timeout=25) as response:
            raw = response.read(8_000_001)
        if len(raw) > 8_000_000:
            raise ProviderFailure("Response exceeds the preflight limit")
        return json.loads(raw)
    except urllib.error.HTTPError as error:
        raise ProviderFailure(f"HTTP {error.code}") from None
    except (urllib.error.URLError, TimeoutError):
        raise ProviderFailure("Transport failure") from None
    except (ValueError, UnicodeError):
        raise ProviderFailure("Invalid JSON response") from None


def rpc(method: str, params: list, endpoint: str = RPC):
    envelope = fetch_json(endpoint, {
        "jsonrpc": "2.0", "id": 1, "method": method, "params": params,
    })
    if envelope.get("error"):
        raise ProviderFailure(f"{method}: RPC {envelope['error'].get('code')}")
    if envelope.get("id") != 1 or "result" not in envelope:
        raise ProviderFailure("Invalid JSON-RPC envelope")
    return envelope["result"]


def integer(value: str) -> int:
    if not isinstance(value, str) or not re.fullmatch(r"0x[0-9a-fA-F]+", value):
        raise ProviderFailure("Invalid hexadecimal quantity")
    result = int(value, 16)
    if not 0 <= result < 2**256:
        raise ProviderFailure("Quantity outside uint256")
    return result


def exact_units(value: int, decimals: int) -> str:
    whole, fractional = divmod(value, 10**decimals)
    return str(whole) if not decimals else f"{whole}.{fractional:0{decimals}d}"


class RobinhoodMainnetReadTests(unittest.TestCase):
    def test_mainnet_identity_from_two_providers(self):
        for endpoint in (RPC, PUBLIC_NODE):
            with self.subTest(provider="official" if endpoint == RPC else "publicnode"):
                self.assertEqual(integer(rpc("eth_chainId", [], endpoint)), CHAIN_ID)

    def test_native_balance_preserves_every_digit(self):
        value = integer(rpc("eth_getBalance", [OWNER, "latest"]))
        text = exact_units(value, 18)
        self.assertEqual(int(text.replace(".", "")), value)
        self.assertGreaterEqual(value, 0)

    def test_real_transaction_and_receipt_agree(self):
        transaction = rpc("eth_getTransactionByHash", [TRANSACTION])
        receipt = rpc("eth_getTransactionReceipt", [TRANSACTION])
        self.assertEqual(transaction["from"].lower(), OWNER)
        self.assertEqual(receipt["transactionHash"].lower(), TRANSACTION)
        self.assertEqual(transaction["blockHash"], receipt["blockHash"])
        self.assertEqual(transaction["blockNumber"], BLOCK)
        self.assertEqual(receipt["status"], "0x1")
        self.assertGreater(integer(receipt["gasUsed"]), 0)
        self.assertGreater(integer(receipt["effectiveGasPrice"]), 0)

    def test_token_balances_for_real_holder_and_contracts(self):
        # This pool received the two canonical tokens in the pinned transaction.
        holder = "0x52e65b17fb6e5ba00ed806f37afcd2daa50271ca"
        total_nonzero = 0
        for contract, decimals in ((USDG, 6), (WETH, 18)):
            with self.subTest(contract=contract):
                actual_decimals = integer(rpc("eth_call", [
                    {"to": contract, "data": "0x313ce567"}, "latest",
                ]))
                self.assertEqual(actual_decimals, decimals)
                value = integer(rpc("eth_call", [
                    {"to": contract, "data": "0x70a08231" + holder[2:].zfill(64)},
                    "latest",
                ]))
                text = exact_units(value, decimals)
                self.assertEqual(int(text.replace(".", "")), value)
                total_nonzero += value > 0
        self.assertGreater(total_nonzero, 0, "Live sample no longer holds either token")

    def test_transfer_history_matches_receipt_and_split_ranges(self):
        def logs(start, end):
            return rpc("eth_getLogs", [{
                "fromBlock": hex(start), "toBlock": hex(end), "topics": [TRANSFER],
            }])
        def identity(log):
            return (log["transactionHash"], log["logIndex"], log["address"])
        height = int(BLOCK, 16)
        complete = logs(height - 1, height)
        split = logs(height - 1, height - 1) + logs(height, height)
        self.assertEqual({identity(x) for x in complete}, {identity(x) for x in split})
        receipt = rpc("eth_getTransactionReceipt", [TRANSACTION])
        expected = [x for x in receipt["logs"] if x.get("topics", [None])[0] == TRANSFER]
        actual = [x for x in complete if x["transactionHash"].lower() == TRANSACTION]
        self.assertTrue(expected)
        self.assertEqual({identity(x) for x in actual}, {identity(x) for x in expected})
        for log in actual:
            if len(log["topics"]) == 3:
                self.assertGreaterEqual(integer(log["data"]), 0)

    def test_notification_block_receipts_need_no_ankr(self):
        block = rpc("eth_getBlockByNumber", [BLOCK, True], PUBLIC_NODE)
        receipts = rpc("eth_getBlockReceipts", [BLOCK], PUBLIC_NODE)
        self.assertEqual(
            {x["hash"] for x in block["transactions"]},
            {x["transactionHash"] for x in receipts},
        )
        self.assertTrue(any(x["transactionHash"] == TRANSACTION for x in receipts))

    def test_official_stock_registry_uses_contract_identity(self):
        payload = fetch_json("https://api.robinhood.com/rhj/assets")
        self.assertIsInstance(payload.get("assets"), list)
        contracts = []
        for asset in payload["assets"]:
            for deployment in asset.get("deployments", []):
                if deployment["chainId"] == CHAIN_ID:
                    contract = deployment["contractAddress"].lower()
                    self.assertRegex(contract, r"^0x[0-9a-f]{40}$")
                    contracts.append(contract)
                    self.assertRegex(asset["currentMultiplier"], r"^[0-9]+\.[0-9]+$")
        self.assertTrue(contracts)
        self.assertEqual(len(contracts), len(set(contracts)))


@unittest.skipUnless(os.environ.get("ROBINHOOD_ANKR_KEY_FILE"), "ANKR key file not provided")
class RobinhoodANKRReadinessTests(unittest.TestCase):
    def test_ankr_supports_all_required_indexed_methods(self):
        key = Path(os.environ["ROBINHOOD_ANKR_KEY_FILE"]).read_text().strip()
        if not key or "\n" in key:
            self.fail("Expected a single API key in the supplied file")
        methods = [
            ("ankr_getAccountBalance", {"blockchain": ["robinhood"], "walletAddress": OWNER, "pageSize": 10}),
            ("ankr_getTransactionsByAddress", {"blockchain": ["robinhood"], "address": OWNER, "pageSize": 10}),
            ("ankr_getTokenTransfers", {"blockchain": ["robinhood"], "address": [OWNER], "pageSize": 10}),
        ]
        for method, params in methods:
            with self.subTest(method=method):
                result = fetch_json("https://rpc.ankr.com/multichain/" + key, {
                    "jsonrpc": "2.0", "id": 1, "method": method, "params": params,
                })
                error = result.get("error", {})
                self.assertFalse(bool(error), f"{method} not usable: RPC {error.get('code')}")
                self.assertIn("result", result)


if __name__ == "__main__":
    unittest.main()

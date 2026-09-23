#!/usr/bin/env python3
"""Read-only XRPL mainnet contract test for Aperture's XRP integration.

This script intentionally exercises only the provider methods used to load
balances, issued-token trust lines, history, fees, ledger state, and reserve
requirements. It never signs or submits a transaction.
"""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request
from typing import Any


DEFAULT_ENDPOINT = "https://xrplcluster.com"
DEFAULT_ACCOUNT = "rG1QQv2nh2gr7RCZ1P8YYcBUKCCN633jCn"


class ProbeFailure(RuntimeError):
    """Raised when the live provider violates the expected XRPL contract."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ProbeFailure(message)


def rpc(
    endpoint: str,
    method: str,
    parameters: dict[str, Any],
) -> dict[str, Any]:
    envelope = {
        "jsonrpc": "2.0",
        "id": method,
        "method": method,
        "params": [parameters],
    }
    request = urllib.request.Request(
        endpoint,
        data=json.dumps(envelope).encode("utf-8"),
        headers={
            "Accept": "application/json",
            "Content-Type": "application/json",
            "User-Agent": "Aperture-XRP-Mainnet-Contract-Test/1.0",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            require(response.status == 200, f"{method}: HTTP {response.status}")
            payload = json.load(response)
    except urllib.error.HTTPError as error:
        body = error.read(1_024).decode("utf-8", errors="replace")
        raise ProbeFailure(
            f"{method}: HTTP {error.code}; response={body!r}"
        ) from error
    except (urllib.error.URLError, TimeoutError) as error:
        raise ProbeFailure(f"{method}: transport failure: {error}") from error

    require(isinstance(payload, dict), f"{method}: response is not an object")
    if "error" in payload:
        raise ProbeFailure(f"{method}: JSON-RPC error: {payload['error']}")
    result = payload.get("result")
    require(isinstance(result, dict), f"{method}: missing result object")
    require(result.get("status") == "success", f"{method}: unsuccessful result")
    return result


def verify_account_info(endpoint: str, account: str) -> None:
    result = rpc(
        endpoint,
        "account_info",
        {"account": account, "ledger_index": "validated", "strict": True},
    )
    data = result.get("account_data")
    require(isinstance(data, dict), "account_info: missing account_data")
    require(data.get("Account") == account, "account_info: account mismatch")
    balance = data.get("Balance")
    require(
        isinstance(balance, str) and balance.isascii() and balance.isdigit(),
        "account_info: Balance is not lossless drops text",
    )
    require(isinstance(data.get("Sequence"), int), "account_info: missing Sequence")
    require(isinstance(data.get("OwnerCount"), int), "account_info: missing OwnerCount")


def verify_account_lines(endpoint: str, account: str) -> None:
    result = rpc(
        endpoint,
        "account_lines",
        {"account": account, "ledger_index": "validated", "limit": 100},
    )
    lines = result.get("lines")
    require(isinstance(lines, list), "account_lines: missing lines array")
    require(lines, "account_lines: representative account has no trust lines")
    for index, line in enumerate(lines):
        require(isinstance(line, dict), f"account_lines[{index}]: not an object")
        require(isinstance(line.get("account"), str), f"account_lines[{index}]: issuer")
        require(isinstance(line.get("currency"), str), f"account_lines[{index}]: currency")
        require(isinstance(line.get("balance"), str), f"account_lines[{index}]: balance")


def verify_account_tx(endpoint: str, account: str) -> None:
    result = rpc(
        endpoint,
        "account_tx",
        {
            "account": account,
            "ledger_index_min": -1,
            "ledger_index_max": -1,
            "binary": False,
            "forward": False,
            "limit": 10,
        },
    )
    transactions = result.get("transactions")
    require(isinstance(transactions, list), "account_tx: missing transactions")
    require(transactions, "account_tx: representative account has no history")
    for index, item in enumerate(transactions):
        require(isinstance(item, dict), f"account_tx[{index}]: not an object")
        require(isinstance(item.get("tx"), dict), f"account_tx[{index}]: missing tx")
        require(isinstance(item.get("meta"), dict), f"account_tx[{index}]: missing meta")
        require(isinstance(item.get("validated"), bool), f"account_tx[{index}]: validated")


def verify_fee(endpoint: str) -> None:
    result = rpc(endpoint, "fee", {})
    drops = result.get("drops")
    require(isinstance(drops, dict), "fee: missing drops")
    for key in ("base_fee", "minimum_fee", "median_fee", "open_ledger_fee"):
        value = drops.get(key)
        require(
            isinstance(value, str) and value.isascii() and value.isdigit(),
            f"fee: {key} is not lossless drops text",
        )


def verify_ledger(endpoint: str) -> None:
    result = rpc(endpoint, "ledger_current", {})
    require(
        isinstance(result.get("ledger_current_index"), int),
        "ledger_current: missing ledger_current_index",
    )


def verify_server_state(endpoint: str) -> None:
    result = rpc(endpoint, "server_state", {})
    state = result.get("state")
    require(isinstance(state, dict), "server_state: missing state")
    validated = state.get("validated_ledger")
    require(isinstance(validated, dict), "server_state: missing validated ledger")
    reserve_base = validated.get("reserve_base")
    reserve_increment = validated.get("reserve_inc")
    require(
        isinstance(reserve_base, int) and reserve_base > 0,
        "server_state: invalid reserve_base",
    )
    require(
        isinstance(reserve_increment, int) and reserve_increment > 0,
        "server_state: invalid reserve_inc",
    )


def main() -> int:
    endpoint = os.environ.get("XRP_MAINNET_ENDPOINT", DEFAULT_ENDPOINT).strip()
    account = os.environ.get("XRP_MAINNET_ACCOUNT", DEFAULT_ACCOUNT).strip()
    require(endpoint.startswith("https://"), "XRP endpoint must use HTTPS")
    require(account.startswith("r"), "XRP account must be a classic address")

    checks = (
        ("account_info", lambda: verify_account_info(endpoint, account)),
        ("account_lines", lambda: verify_account_lines(endpoint, account)),
        ("account_tx", lambda: verify_account_tx(endpoint, account)),
        ("fee", lambda: verify_fee(endpoint)),
        ("ledger_current", lambda: verify_ledger(endpoint)),
        ("server_state", lambda: verify_server_state(endpoint)),
    )
    for name, check in checks:
        check()
        print(f"PASS {name}")
    print("PASS XRP mainnet read-only provider contract")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ProbeFailure as error:
        print(f"FAIL {error}", file=sys.stderr)
        raise SystemExit(1) from error

#!/usr/bin/env python3
"""Live mainnet Electrum balance benchmark used by Aperture maintainers.

The probe validates each server's genesis block before timing the exact
`blockchain.scripthash.get_balance` and subscription requests used by the iOS
app. Each endpoint is queried with both a deterministic unused address and a
public mainnet address derived from Bitcoin's genesis-reward address hash160.
No wallet secret or user address is read by this script.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import socket
import ssl
import statistics
import time
from dataclasses import asdict, dataclass
from pathlib import Path


ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

CHAINS = {
    "bitcoin": {
        "version": 0,
        "genesis": "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f",
        "servers": [
            ("electrum.blockstream.info", 50002),
            ("blockstream.info", 700),
            ("electrum.jhoenicke.de", 50002),
            ("bitcoin.stackwallet.com", 50002),
        ],
    },
    "bitcoin_cash": {
        "version": 0,
        "genesis": "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f",
        "servers": [
            ("electrum.imaginary.cash", 50002),
            ("bch.imaginary.cash", 50002),
            ("bch.loping.net", 50002),
            ("bch.cyberbits.eu", 50002),
            ("cashnode.bch.ninja", 50002),
            ("bch.soul-dev.com", 50002),
            ("bitcoincash.stackwallet.com", 50002),
        ],
    },
    "litecoin": {
        "version": 48,
        "genesis": "12a765e31ffd4059bada1e25190f6e98c99d9714d334efa41a195a7e7e04bfe2",
        "servers": [
            ("electrum1.cipig.net", 20063),
            ("electrum2.cipig.net", 20063),
            ("litecoin.stackwallet.com", 20063),
            ("ltc.rentonisk.com", 50002),
        ],
    },
    "dogecoin": {
        "version": 30,
        "genesis": "1a91e3dace36e2be3bf030a65679fe821aa1d6ef92e7c9902eb318182c355691",
        "servers": [
            ("electrum1.cipig.net", 20060),
            ("electrum2.cipig.net", 20060),
            ("electrum3.cipig.net", 20060),
            ("dogecoin.stackwallet.com", 50022),
        ],
    },
}


@dataclass
class ProbeResult:
    chain: str
    endpoint: str
    address: str
    public_address: str
    verified_mainnet: bool
    cold_ms: float | None
    warm_ms: list[float]
    median_warm_ms: float | None
    confirmed_atomic: int | None
    unconfirmed_atomic: int | None
    public_confirmed_atomic: int | None
    public_unconfirmed_atomic: int | None
    subscription_supported: bool
    cold_to_warm_speedup: float | None
    error: str | None


def double_sha256(value: bytes) -> bytes:
    return hashlib.sha256(hashlib.sha256(value).digest()).digest()


def base58check(version: int, payload: bytes) -> str:
    value = bytes([version]) + payload
    raw = value + double_sha256(value)[:4]
    number = int.from_bytes(raw, "big")
    encoded = ""
    while number:
        number, remainder = divmod(number, 58)
        encoded = ALPHABET[remainder] + encoded
    leading_zeroes = len(raw) - len(raw.lstrip(b"\0"))
    return "1" * leading_zeroes + encoded


def base58check_payload(address: str) -> bytes:
    number = 0
    for character in address:
        number = number * 58 + ALPHABET.index(character)
    decoded = number.to_bytes((number.bit_length() + 7) // 8, "big")
    leading_zeroes = len(address) - len(address.lstrip("1"))
    raw = b"\0" * leading_zeroes + decoded
    if len(raw) != 25 or double_sha256(raw[:-4])[:4] != raw[-4:]:
        raise ValueError("invalid public Base58Check fixture")
    return raw[1:-4]


def probe_identity(chain: str, version: int) -> tuple[str, str]:
    payload = hashlib.sha256(f"aperture-electrum-probe:{chain}".encode()).digest()[:20]
    address = base58check(version, payload)
    script = bytes.fromhex("76a914") + payload + bytes.fromhex("88ac")
    script_hash = hashlib.sha256(script).digest()[::-1].hex()
    return address, script_hash


def public_probe_identity(version: int) -> tuple[str, str]:
    # Satoshi's public genesis-reward address. Re-encoding its public hash160
    # with each network's P2PKH version yields a valid mainnet address while
    # keeping this test completely independent of private wallet material.
    payload = base58check_payload("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa")
    address = base58check(version, payload)
    script = bytes.fromhex("76a914") + payload + bytes.fromhex("88ac")
    script_hash = hashlib.sha256(script).digest()[::-1].hex()
    return address, script_hash


class ElectrumSocket:
    def __init__(self, host: str, port: int, timeout: float):
        started = time.perf_counter()
        raw = socket.create_connection((host, port), timeout=timeout)
        raw.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        context = ssl.create_default_context()
        self.socket = context.wrap_socket(raw, server_hostname=host)
        self.socket.settimeout(timeout)
        self.buffer = b""
        self.connect_ms = (time.perf_counter() - started) * 1000
        self.request_id = 0

    def close(self) -> None:
        self.socket.close()

    def call(self, method: str, params: list[object]) -> tuple[object, float]:
        self.request_id += 1
        payload = json.dumps(
            {"id": self.request_id, "method": method, "params": params},
            separators=(",", ":"),
        ).encode() + b"\n"
        started = time.perf_counter()
        self.socket.sendall(payload)
        while True:
            if b"\n" in self.buffer:
                line, self.buffer = self.buffer.split(b"\n", 1)
                if not line:
                    continue
                response = json.loads(line)
                if response.get("id") != self.request_id:
                    continue
                if response.get("error") is not None:
                    raise RuntimeError(json.dumps(response["error"], sort_keys=True))
                return response.get("result"), (time.perf_counter() - started) * 1000
            chunk = self.socket.recv(65536)
            if not chunk:
                raise ConnectionError("server closed the TLS connection")
            self.buffer += chunk


def probe(chain: str, host: str, port: int, repeats: int, timeout: float) -> ProbeResult:
    configuration = CHAINS[chain]
    address, script_hash = probe_identity(chain, int(configuration["version"]))
    public_address, public_script_hash = public_probe_identity(
        int(configuration["version"])
    )
    endpoint = f"{host}:{port}"
    connection: ElectrumSocket | None = None
    try:
        connection = ElectrumSocket(host, port, timeout)
        negotiated, negotiation_ms = connection.call(
            "server.version", ["Aperture", "1.4"]
        )
        if not isinstance(negotiated, list) or len(negotiated) != 2:
            raise RuntimeError("invalid protocol negotiation response")
        header, header_ms = connection.call("blockchain.block.header", [0])
        if not isinstance(header, str) or len(header) < 160:
            raise RuntimeError("invalid genesis header response")
        header_hash = double_sha256(bytes.fromhex(header[:160]))[::-1].hex()
        if header_hash != configuration["genesis"]:
            raise RuntimeError(f"wrong mainnet genesis {header_hash}")
        balance, balance_ms = connection.call(
            "blockchain.scripthash.get_balance", [script_hash]
        )
        if not isinstance(balance, dict):
            raise RuntimeError("invalid balance response")
        confirmed = balance.get("confirmed")
        unconfirmed = balance.get("unconfirmed")
        if not isinstance(confirmed, int) or not isinstance(unconfirmed, int):
            raise RuntimeError("balance quantities were not integers")
        public_balance, public_balance_ms = connection.call(
            "blockchain.scripthash.get_balance", [public_script_hash]
        )
        if not isinstance(public_balance, dict):
            raise RuntimeError("invalid public-address balance response")
        public_confirmed = public_balance.get("confirmed")
        public_unconfirmed = public_balance.get("unconfirmed")
        if not isinstance(public_confirmed, int) or not isinstance(
            public_unconfirmed, int
        ):
            raise RuntimeError("public-address quantities were not integers")
        subscription_status, _ = connection.call(
            "blockchain.scripthash.subscribe", [public_script_hash]
        )
        if subscription_status is not None and not isinstance(
            subscription_status, str
        ):
            raise RuntimeError("invalid subscription response")
        warm: list[float] = []
        for _ in range(repeats):
            repeated, elapsed = connection.call(
                "blockchain.scripthash.get_balance", [public_script_hash]
            )
            if not isinstance(repeated, dict):
                raise RuntimeError("invalid repeated balance response")
            warm.append(round(elapsed, 2))
        cold_ms = connection.connect_ms + negotiation_ms + header_ms + balance_ms
        cold_ms += public_balance_ms
        median_warm_ms = statistics.median(warm)
        return ProbeResult(
            chain=chain,
            endpoint=endpoint,
            address=address,
            public_address=public_address,
            verified_mainnet=True,
            cold_ms=round(cold_ms, 2),
            warm_ms=warm,
            median_warm_ms=round(median_warm_ms, 2),
            confirmed_atomic=confirmed,
            unconfirmed_atomic=unconfirmed,
            public_confirmed_atomic=public_confirmed,
            public_unconfirmed_atomic=public_unconfirmed,
            subscription_supported=True,
            cold_to_warm_speedup=round(cold_ms / median_warm_ms, 2),
            error=None,
        )
    except Exception as error:  # Deliberately records every candidate failure.
        return ProbeResult(
            chain=chain,
            endpoint=endpoint,
            address=address,
            public_address=public_address,
            verified_mainnet=False,
            cold_ms=None,
            warm_ms=[],
            median_warm_ms=None,
            confirmed_atomic=None,
            unconfirmed_atomic=None,
            public_confirmed_atomic=None,
            public_unconfirmed_atomic=None,
            subscription_supported=False,
            cold_to_warm_speedup=None,
            error=f"{type(error).__name__}: {error}",
        )
    finally:
        if connection is not None:
            connection.close()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--timeout", type=float, default=8.0)
    parser.add_argument("--output", type=Path)
    arguments = parser.parse_args()
    results: list[ProbeResult] = []
    for chain, configuration in CHAINS.items():
        for host, port in configuration["servers"]:
            result = probe(chain, host, port, arguments.repeats, arguments.timeout)
            results.append(result)
            status = (
                f"{result.median_warm_ms:.2f} ms warm"
                if result.error is None
                else result.error
            )
            print(f"{chain:13} {result.endpoint:38} {status}")

    document = {
        "generated_at_unix": int(time.time()),
        "method": (
            "TLS server.version + genesis verification + unused/funded "
            "get_balance + scripthash subscription"
        ),
        "results": [asdict(result) for result in results],
    }
    encoded = json.dumps(document, indent=2, sort_keys=True) + "\n"
    if arguments.output is not None:
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        arguments.output.write_text(encoded)
    else:
        print(encoded)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

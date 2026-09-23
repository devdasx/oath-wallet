#!/usr/bin/env python3
"""Benchmark large Bitcoin Electrum scans with public mainnet scripts.

The corpus is collected from recent Bitcoin blocks through Blockstream's
public mainnet API. The benchmark never reads Aperture data or wallet secrets.
It compares Aperture's former newline-pipelined request pattern with the
JSON-array batching and bounded connection pool used by Muun Recovery Tool.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import socket
import ssl
import statistics
import time
import urllib.request
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Iterable


GENESIS_HASH = "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f"
BLOCKSTREAM_API = "https://blockstream.info/api"

APP_SERVERS = [
    "blockstream.info:700",
    "electrum.blockstream.info:50002",
    "bitcoin.stackwallet.com:50002",
]

# The first entries from Muun Recovery Tool's surveyed, batch-capable list.
MUUN_SERVERS = [
    "electrum.coinext.com.br:50002",
    "fulcrum.sethforprivacy.com:50002",
    "mainnet.foundationdevices.com:50002",
    "btc.lastingcoin.net:50002",
    "de.poiuty.com:50002",
    "electrum.jochen-hoenicke.de:50006",
    "e.keff.org:50002",
    "e2.keff.org:50002",
    "fulcrum.grey.pw:51002",
    "fortress.qtornado.com:443",
    "f.keff.org:50002",
    "electrum.petrkr.net:50002",
]


@dataclass(frozen=True)
class CorpusMetadata:
    count: int
    tip_height: int
    block_heights: list[int]
    block_hashes: list[str]


@dataclass(frozen=True)
class SurveyResult:
    endpoint: str
    server_implementation: str | None
    protocol_version: str | None
    connection_ms: float | None
    batch_2_ms: float | None
    batch_100_ms: float | None
    batch_supported: bool
    verified_mainnet: bool
    error: str | None


@dataclass(frozen=True)
class BenchmarkResult:
    label: str
    method: str
    endpoints: list[str]
    request_count: int
    connection_count: int
    batch_size: int
    elapsed_seconds: float
    requests_per_second: float
    nonempty_results: int
    response_digest: str
    sample_elapsed_seconds: list[float]


class ElectrumBatchLimitError(RuntimeError):
    """The server accepted JSON batches but rejected this batch size."""


def read_varint(data: bytes, offset: int) -> tuple[int, int]:
    prefix = data[offset]
    offset += 1
    if prefix < 0xFD:
        return prefix, offset
    widths = {0xFD: 2, 0xFE: 4, 0xFF: 8}
    width = widths[prefix]
    end = offset + width
    return int.from_bytes(data[offset:end], "little"), end


def parse_block_output_scripts(raw_block: bytes) -> list[bytes]:
    """Return standard address scripts from a serialized Bitcoin block."""
    offset = 80
    transaction_count, offset = read_varint(raw_block, offset)
    scripts: list[bytes] = []
    for _ in range(transaction_count):
        offset += 4
        is_segwit = raw_block[offset:offset + 2] == b"\x00\x01"
        if is_segwit:
            offset += 2
        input_count, offset = read_varint(raw_block, offset)
        for _ in range(input_count):
            offset += 36
            script_length, offset = read_varint(raw_block, offset)
            offset += script_length + 4
        output_count, offset = read_varint(raw_block, offset)
        for _ in range(output_count):
            offset += 8
            script_length, offset = read_varint(raw_block, offset)
            script = raw_block[offset:offset + script_length]
            offset += script_length
            if is_standard_address_script(script):
                scripts.append(script)
        if is_segwit:
            for _ in range(input_count):
                item_count, offset = read_varint(raw_block, offset)
                for _ in range(item_count):
                    item_length, offset = read_varint(raw_block, offset)
                    offset += item_length
        offset += 4
    if offset != len(raw_block):
        raise ValueError(
            f"block parser stopped at {offset} of {len(raw_block)} bytes"
        )
    return scripts


def is_standard_address_script(script: bytes) -> bool:
    p2pkh = (
        len(script) == 25
        and script[:3] == bytes.fromhex("76a914")
        and script[-2:] == bytes.fromhex("88ac")
    )
    p2sh = (
        len(script) == 23
        and script[:2] == bytes.fromhex("a914")
        and script[-1:] == bytes.fromhex("87")
    )
    witness = (
        len(script) in (22, 34)
        and script[0] in (0x00, 0x51)
        and script[1] == len(script) - 2
    )
    return p2pkh or p2sh or witness


def fetch(url: str, timeout: float) -> bytes:
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "Aperture-Electrum-Benchmark/1.0"},
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read()


def public_mainnet_corpus(
    count: int,
    timeout: float,
) -> tuple[list[str], CorpusMetadata]:
    tip_height = int(fetch(f"{BLOCKSTREAM_API}/blocks/tip/height", timeout))
    unique: dict[str, None] = {}
    block_heights: list[int] = []
    block_hashes: list[str] = []
    # Avoid the tip so every corpus transaction is deeply enough indexed by
    # independently operated Electrum servers during a repeatable benchmark.
    height = tip_height - 24
    while len(unique) < count:
        block_hash = fetch(
            f"{BLOCKSTREAM_API}/block-height/{height}", timeout
        ).decode().strip()
        raw_block = fetch(
            f"{BLOCKSTREAM_API}/block/{block_hash}/raw", timeout
        )
        for script in parse_block_output_scripts(raw_block):
            script_hash = hashlib.sha256(script).digest()[::-1].hex()
            unique.setdefault(script_hash, None)
            if len(unique) == count:
                break
        block_heights.append(height)
        block_hashes.append(block_hash)
        height -= 1
        if len(block_heights) > 20:
            raise RuntimeError("could not collect enough standard outputs")
    return list(unique), CorpusMetadata(
        count=count,
        tip_height=tip_height,
        block_heights=block_heights,
        block_hashes=block_hashes,
    )


class ElectrumSocket:
    def __init__(self, endpoint: str, timeout: float):
        self.endpoint = endpoint
        host, raw_port = endpoint.rsplit(":", 1)
        started = time.perf_counter()
        raw = socket.create_connection((host, int(raw_port)), timeout=timeout)
        raw.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        context = ssl.create_default_context()
        self.socket = context.wrap_socket(raw, server_hostname=host)
        self.socket.settimeout(timeout)
        self.buffer = b""
        self.next_request_id = 0
        self.connection_ms = (time.perf_counter() - started) * 1_000

    def close(self) -> None:
        self.socket.close()

    def next_id(self) -> int:
        self.next_request_id += 1
        return self.next_request_id

    def read_line(self) -> bytes:
        while b"\n" not in self.buffer:
            chunk = self.socket.recv(1_048_576)
            if not chunk:
                raise ConnectionError("server closed the TLS connection")
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\n", 1)
        return line

    def call(self, method: str, params: list[object]) -> tuple[object, float]:
        request_id = self.next_id()
        payload = encode_request(request_id, method, params) + b"\n"
        started = time.perf_counter()
        self.socket.sendall(payload)
        while True:
            response = json.loads(self.read_line())
            if response.get("id") != request_id:
                continue
            validate_response(response)
            return response.get("result"), elapsed_ms(started)

    def call_json_batch(
        self,
        method: str,
        parameters: list[str],
    ) -> tuple[list[object], float]:
        ids = [self.next_id() for _ in parameters]
        requests = [
            {"id": request_id, "method": method, "params": [parameter]}
            for request_id, parameter in zip(ids, parameters, strict=True)
        ]
        started = time.perf_counter()
        self.socket.sendall(
            json.dumps(requests, separators=(",", ":")).encode() + b"\n"
        )
        response = json.loads(self.read_line())
        if not isinstance(response, list):
            if isinstance(response, dict):
                error = response.get("error")
                if isinstance(error, dict):
                    code = error.get("code")
                    message = str(error.get("message", ""))
                    lowered = message.lower()
                    if (
                        code == 4
                        or "batch limit" in lowered
                        or "batch request timed out" in lowered
                        or "too many requests" in lowered
                    ):
                        raise ElectrumBatchLimitError(
                            f"{self.endpoint}: {message or 'batch limit exceeded'}"
                        )
            raise ValueError(
                f"{self.endpoint} did not return a JSON batch response "
                f"for {method}: {str(response)[:400]}"
            )
        by_id = {item.get("id"): item for item in response}
        if set(by_id) != set(ids):
            raise ValueError("batch response ids did not match requests")
        values: list[object] = []
        for request_id in ids:
            item = by_id[request_id]
            validate_response(item)
            values.append(item.get("result"))
        return values, elapsed_ms(started)

    def call_pipeline(
        self,
        method: str,
        parameters: list[str],
    ) -> tuple[list[object], float]:
        ids = [self.next_id() for _ in parameters]
        started = time.perf_counter()
        # This intentionally mirrors the old app path: one Network.framework
        # send per address, rather than one JSON-array write per batch.
        for request_id, parameter in zip(ids, parameters, strict=True):
            self.socket.sendall(
                encode_request(request_id, method, [parameter]) + b"\n"
            )
        by_id: dict[int, dict[str, object]] = {}
        while len(by_id) < len(ids):
            item = json.loads(self.read_line())
            if isinstance(item, dict) and item.get("id") in ids:
                by_id[int(item["id"])] = item
        values: list[object] = []
        for request_id in ids:
            item = by_id[request_id]
            validate_response(item)
            values.append(item.get("result"))
        return values, elapsed_ms(started)

    def call_packed_pipeline(
        self,
        method: str,
        parameters: list[str],
    ) -> tuple[list[object], float]:
        ids = [self.next_id() for _ in parameters]
        payload = b"".join(
            encode_request(request_id, method, [parameter]) + b"\n"
            for request_id, parameter in zip(ids, parameters, strict=True)
        )
        started = time.perf_counter()
        self.socket.sendall(payload)
        by_id: dict[int, dict[str, object]] = {}
        while len(by_id) < len(ids):
            item = json.loads(self.read_line())
            if isinstance(item, dict) and item.get("id") in ids:
                by_id[int(item["id"])] = item
        values: list[object] = []
        for request_id in ids:
            item = by_id[request_id]
            validate_response(item)
            values.append(item.get("result"))
        return values, elapsed_ms(started)


def encode_request(request_id: int, method: str, params: list[object]) -> bytes:
    return json.dumps(
        {"id": request_id, "method": method, "params": params},
        separators=(",", ":"),
    ).encode()


def validate_response(response: dict[str, object]) -> None:
    if response.get("error") is not None:
        raise RuntimeError(json.dumps(response["error"], sort_keys=True))
    if "result" not in response:
        raise ValueError("Electrum response omitted result")


def elapsed_ms(started: float) -> float:
    return (time.perf_counter() - started) * 1_000


def verify_mainnet(connection: ElectrumSocket) -> tuple[str, str]:
    version, _ = connection.call("server.version", ["Aperture", "1.4"])
    if not isinstance(version, list) or len(version) != 2:
        raise ValueError("invalid server.version response")
    header, _ = connection.call("blockchain.block.header", [0])
    if not isinstance(header, str) or len(header) < 160:
        raise ValueError("invalid genesis header response")
    raw_header = bytes.fromhex(header[:160])
    digest = hashlib.sha256(hashlib.sha256(raw_header).digest()).digest()
    if digest[::-1].hex() != GENESIS_HASH:
        raise ValueError("server is not Bitcoin mainnet")
    return str(version[0]), str(version[1])


def survey_endpoint(
    endpoint: str,
    corpus: list[str],
    timeout: float,
) -> SurveyResult:
    connection: ElectrumSocket | None = None
    try:
        connection = ElectrumSocket(endpoint, timeout)
        implementation, protocol = verify_mainnet(connection)
        _, batch_2_ms = connection.call_json_batch(
            "blockchain.scripthash.get_balance", corpus[:2]
        )
        _, batch_100_ms = connection.call_json_batch(
            "blockchain.scripthash.get_balance", corpus[:100]
        )
        return SurveyResult(
            endpoint=endpoint,
            server_implementation=implementation,
            protocol_version=protocol,
            connection_ms=round(connection.connection_ms, 2),
            batch_2_ms=round(batch_2_ms, 2),
            batch_100_ms=round(batch_100_ms, 2),
            batch_supported=True,
            verified_mainnet=True,
            error=None,
        )
    except Exception as error:
        return SurveyResult(
            endpoint=endpoint,
            server_implementation=None,
            protocol_version=None,
            connection_ms=None,
            batch_2_ms=None,
            batch_100_ms=None,
            batch_supported=False,
            verified_mainnet=False,
            error=f"{type(error).__name__}: {error}",
        )
    finally:
        if connection is not None:
            connection.close()


def chunks(values: list[str], size: int) -> list[list[str]]:
    return [values[index:index + size] for index in range(0, len(values), size)]


def response_summary(values: Iterable[object]) -> tuple[int, str]:
    normalized = json.dumps(list(values), separators=(",", ":"), sort_keys=True)
    parsed = json.loads(normalized)
    nonempty = sum(
        value not in (None, [], {}, {"confirmed": 0, "unconfirmed": 0})
        for value in parsed
    )
    return nonempty, hashlib.sha256(normalized.encode()).hexdigest()


def benchmark_pipeline(
    endpoint: str,
    method: str,
    corpus: list[str],
    timeout: float,
    chunk_size: int,
) -> BenchmarkResult:
    connection = ElectrumSocket(endpoint, timeout)
    try:
        verify_mainnet(connection)
        started = time.perf_counter()
        values: list[object] = []
        for chunk in chunks(corpus, chunk_size):
            result, _ = connection.call_pipeline(method, chunk)
            values.extend(result)
        elapsed = time.perf_counter() - started
    finally:
        connection.close()
    nonempty, digest = response_summary(values)
    return BenchmarkResult(
        label="legacy_newline_pipeline",
        method=method,
        endpoints=[endpoint],
        request_count=len(corpus),
        connection_count=1,
        batch_size=chunk_size,
        elapsed_seconds=round(elapsed, 4),
        requests_per_second=round(len(corpus) / elapsed, 2),
        nonempty_results=nonempty,
        response_digest=digest,
        sample_elapsed_seconds=[round(elapsed, 4)],
    )


def benchmark_batch_pool(
    endpoints: list[str],
    method: str,
    corpus: list[str],
    timeout: float,
    batch_size: int,
    connection_count: int,
) -> BenchmarkResult:
    connections = [
        ElectrumSocket(endpoints[index % len(endpoints)], timeout)
        for index in range(connection_count)
    ]
    try:
        for connection in connections:
            verify_mainnet(connection)
        work = [
            (index, corpus[index:index + batch_size])
            for index in range(0, len(corpus), batch_size)
        ]
        assignments = [work[index::len(connections)] for index in range(len(connections))]

        def worker(
            connection: ElectrumSocket,
            assigned: list[tuple[int, list[str]]],
        ) -> list[tuple[int, list[object]]]:
            output: list[tuple[int, list[object]]] = []

            def request_with_adaptive_split(
                start: int,
                chunk: list[str],
            ) -> None:
                try:
                    result, _ = connection.call_json_batch(method, chunk)
                    output.append((start, result))
                except ElectrumBatchLimitError:
                    if len(chunk) == 1:
                        raise
                    midpoint = len(chunk) // 2
                    request_with_adaptive_split(start, chunk[:midpoint])
                    request_with_adaptive_split(
                        start + midpoint,
                        chunk[midpoint:],
                    )

            for start, chunk in assigned:
                request_with_adaptive_split(start, chunk)
            return output

        started = time.perf_counter()
        with concurrent.futures.ThreadPoolExecutor(
            max_workers=len(connections)
        ) as executor:
            futures = [
                executor.submit(worker, connection, assignment)
                for connection, assignment in zip(
                    connections, assignments, strict=True
                )
            ]
            indexed = [item for future in futures for item in future.result()]
        elapsed = time.perf_counter() - started
    finally:
        for connection in connections:
            connection.close()
    values = [value for _, group in sorted(indexed) for value in group]
    nonempty, digest = response_summary(values)
    return BenchmarkResult(
        label="json_batch_connection_pool",
        method=method,
        endpoints=endpoints,
        request_count=len(corpus),
        connection_count=connection_count,
        batch_size=batch_size,
        elapsed_seconds=round(elapsed, 4),
        requests_per_second=round(len(corpus) / elapsed, 2),
        nonempty_results=nonempty,
        response_digest=digest,
        sample_elapsed_seconds=[round(elapsed, 4)],
    )


def benchmark_packed_pipeline_pool(
    endpoints: list[str],
    method: str,
    corpus: list[str],
    timeout: float,
    batch_size: int,
    connection_count: int,
) -> BenchmarkResult:
    connections = [
        ElectrumSocket(endpoints[index % len(endpoints)], timeout)
        for index in range(connection_count)
    ]
    try:
        for connection in connections:
            verify_mainnet(connection)
        work = [
            (index, corpus[index:index + batch_size])
            for index in range(0, len(corpus), batch_size)
        ]
        assignments = [
            work[index::len(connections)]
            for index in range(len(connections))
        ]

        def worker(
            connection: ElectrumSocket,
            assigned: list[tuple[int, list[str]]],
        ) -> list[tuple[int, list[object]]]:
            output: list[tuple[int, list[object]]] = []
            for start, chunk in assigned:
                result, _ = connection.call_packed_pipeline(method, chunk)
                output.append((start, result))
            return output

        started = time.perf_counter()
        with concurrent.futures.ThreadPoolExecutor(
            max_workers=len(connections)
        ) as executor:
            futures = [
                executor.submit(worker, connection, assignment)
                for connection, assignment in zip(
                    connections, assignments, strict=True
                )
            ]
            indexed = [item for future in futures for item in future.result()]
        elapsed = time.perf_counter() - started
    finally:
        for connection in connections:
            connection.close()
    values = [value for _, group in sorted(indexed) for value in group]
    nonempty, digest = response_summary(values)
    return BenchmarkResult(
        label="packed_pipeline_connection_pool",
        method=method,
        endpoints=endpoints,
        request_count=len(corpus),
        connection_count=connection_count,
        batch_size=batch_size,
        elapsed_seconds=round(elapsed, 4),
        requests_per_second=round(len(corpus) / elapsed, 2),
        nonempty_results=nonempty,
        response_digest=digest,
        sample_elapsed_seconds=[round(elapsed, 4)],
    )


def median_benchmark(
    repetitions: int,
    operation,
) -> BenchmarkResult:
    samples = [operation() for _ in range(repetitions)]
    representative = samples[-1]
    elapsed_samples = [sample.elapsed_seconds for sample in samples]
    elapsed = statistics.median(elapsed_samples)
    return BenchmarkResult(
        label=representative.label,
        method=representative.method,
        endpoints=representative.endpoints,
        request_count=representative.request_count,
        connection_count=representative.connection_count,
        batch_size=representative.batch_size,
        elapsed_seconds=round(elapsed, 4),
        requests_per_second=round(
            representative.request_count / elapsed,
            2,
        ),
        nonempty_results=representative.nonempty_results,
        response_digest=representative.response_digest,
        sample_elapsed_seconds=elapsed_samples,
    )


def parse_servers(values: list[str] | None) -> list[str]:
    if not values:
        return list(dict.fromkeys(APP_SERVERS + MUUN_SERVERS))
    return list(dict.fromkeys(values))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--count", type=int, default=5_000)
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--server", action="append", dest="servers")
    parser.add_argument("--survey-only", action="store_true")
    parser.add_argument("--benchmark-server", action="append")
    parser.add_argument(
        "--method",
        action="append",
        choices=("balance", "history"),
        help="Benchmark only the selected operation; repeat for both.",
    )
    parser.add_argument("--connections", type=int, default=6)
    parser.add_argument("--batch-size", type=int, default=100)
    parser.add_argument("--legacy-chunk-size", type=int, default=512)
    parser.add_argument("--repetitions", type=int, default=1)
    parser.add_argument("--skip-legacy", action="store_true")
    parser.add_argument("--skip-json-batch", action="store_true")
    parser.add_argument("--skip-packed-pipeline", action="store_true")
    parser.add_argument("--output", type=Path)
    arguments = parser.parse_args()
    if arguments.count < 100 or arguments.count > 20_000:
        parser.error("--count must be between 100 and 20000")
    if arguments.repetitions < 1 or arguments.repetitions > 10:
        parser.error("--repetitions must be between 1 and 10")

    corpus, metadata = public_mainnet_corpus(
        arguments.count, arguments.timeout
    )
    servers = parse_servers(arguments.servers)
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
        survey_results = list(
            executor.map(
                lambda endpoint: survey_endpoint(
                    endpoint, corpus, arguments.timeout
                ),
                servers,
            )
        )
    survey_results.sort(
        key=lambda result: (
            not result.batch_supported,
            result.batch_100_ms or float("inf"),
        )
    )
    for result in survey_results:
        status = (
            f"batch100={result.batch_100_ms:.2f}ms"
            if result.batch_supported
            else result.error
        )
        print(f"{result.endpoint:42} {status}")

    benchmark_results: list[BenchmarkResult] = []
    if not arguments.survey_only:
        selected = arguments.benchmark_server or [
            result.endpoint
            for result in survey_results
            if result.batch_supported
        ][:3]
        if not selected:
            raise RuntimeError("no verified batch-capable servers")
        baseline_endpoint = next(
            (
                endpoint for endpoint in APP_SERVERS
                if any(
                    result.endpoint == endpoint and result.batch_supported
                    for result in survey_results
                )
            ),
            selected[0],
        )
        method_names = arguments.method or ["balance", "history"]
        methods = {
            "balance": "blockchain.scripthash.get_balance",
            "history": "blockchain.scripthash.get_history",
        }
        for method_name in method_names:
            method = methods[method_name]
            if not arguments.skip_legacy:
                benchmark_results.append(
                    median_benchmark(
                        arguments.repetitions,
                        lambda: benchmark_pipeline(
                            baseline_endpoint,
                            method,
                            corpus,
                            arguments.timeout,
                            arguments.legacy_chunk_size,
                        ),
                    )
                )
                print(
                    f"{benchmark_results[-1].label:28} "
                    f"{method.rsplit('.', 1)[-1]:11} "
                    f"{benchmark_results[-1].elapsed_seconds:8.4f}s "
                    f"{benchmark_results[-1].requests_per_second:9.2f} req/s"
                )
            if not arguments.skip_json_batch:
                benchmark_results.append(
                    median_benchmark(
                        arguments.repetitions,
                        lambda: benchmark_batch_pool(
                            selected,
                            method,
                            corpus,
                            arguments.timeout,
                            arguments.batch_size,
                            arguments.connections,
                        ),
                    )
                )
                print(
                    f"{benchmark_results[-1].label:28} "
                    f"{method.rsplit('.', 1)[-1]:11} "
                    f"{benchmark_results[-1].elapsed_seconds:8.4f}s "
                    f"{benchmark_results[-1].requests_per_second:9.2f} req/s"
                )
            if not arguments.skip_packed_pipeline:
                benchmark_results.append(
                    median_benchmark(
                        arguments.repetitions,
                        lambda: benchmark_packed_pipeline_pool(
                            selected,
                            method,
                            corpus,
                            arguments.timeout,
                            arguments.batch_size,
                            arguments.connections,
                        ),
                    )
                )
                print(
                    f"{benchmark_results[-1].label:28} "
                    f"{method.rsplit('.', 1)[-1]:11} "
                    f"{benchmark_results[-1].elapsed_seconds:8.4f}s "
                    f"{benchmark_results[-1].requests_per_second:9.2f} req/s"
                )

    document = {
        "generated_at_unix": int(time.time()),
        "corpus": asdict(metadata),
        "survey": [asdict(result) for result in survey_results],
        "benchmarks": [asdict(result) for result in benchmark_results],
    }
    encoded = json.dumps(document, indent=2, sort_keys=True) + "\n"
    if arguments.output:
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        arguments.output.write_text(encoded)
    else:
        print(encoded)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

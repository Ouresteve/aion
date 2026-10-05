#!/usr/bin/env python3
"""Concurrent Aion transaction load generator.

Requires: pip install cryptography
"""

from __future__ import annotations

import argparse
import concurrent.futures
import struct
import time
import urllib.request
from dataclasses import dataclass

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

VERSION = 1
TRANSACTION_TAG = 1
TRANSACTION_PAYLOAD_SIZE = 152
FRAME_HEADER_SIZE = 6
# Matches the deterministic development account funded by `aion node`.
DEVELOPMENT_SENDER_SEED = 9


@dataclass(frozen=True)
class LoadConfig:
    host: str
    peer_port: int
    metrics_port: int
    count: int
    connections: int
    amount: int


def deterministic_private_key(byte_value: int) -> Ed25519PrivateKey:
    return Ed25519PrivateKey.from_private_bytes(bytes([byte_value]) * 32)


def encode_transaction(sender_key: Ed25519PrivateKey, receiver: bytes, nonce: int, amount: int) -> bytes:
    sender = sender_key.public_key().public_bytes_raw()
    message = sender + receiver + amount.to_bytes(16, "little") + nonce.to_bytes(8, "little")
    signature = sender_key.sign(message)
    payload = message + signature
    assert len(payload) == TRANSACTION_PAYLOAD_SIZE
    return bytes((VERSION, TRANSACTION_TAG)) + struct.pack("<I", len(payload)) + payload


def send_range(config: LoadConfig, start: int, end: int) -> int:
    sender_key = deterministic_private_key(DEVELOPMENT_SENDER_SEED)
    receiver = deterministic_private_key(3).public_key().public_bytes_raw()

    import socket

    with socket.create_connection((config.host, config.peer_port), timeout=10) as connection:
        for nonce in range(start, end):
            connection.sendall(encode_transaction(sender_key, receiver, nonce, config.amount))
    return end - start


def scrape_metrics(config: LoadConfig) -> str:
    url = f"http://{config.host}:{config.metrics_port}/metrics"
    with urllib.request.urlopen(url, timeout=5) as response:
        return response.read().decode("utf-8")


def metric_value(metrics: str, name: str) -> int:
    prefix = f"{name} "
    for line in metrics.splitlines():
        if line.startswith(prefix):
            return int(line[len(prefix):])
    return 0


def wait_for_metric(config: LoadConfig, name: str, expected: int, timeout: float) -> tuple[str, float]:
    started = time.perf_counter()
    while True:
        metrics = scrape_metrics(config)
        if metric_value(metrics, name) >= expected:
            return metrics, time.perf_counter() - started
        if time.perf_counter() - started >= timeout:
            raise TimeoutError(f"{name} did not reach {expected}")
        time.sleep(0.05)


def split_ranges(count: int, connections: int) -> list[tuple[int, int]]:
    connections = min(count, connections)
    base, remainder = divmod(count, connections)
    ranges: list[tuple[int, int]] = []
    start = 0
    for index in range(connections):
        size = base + (1 if index < remainder else 0)
        ranges.append((start, start + size))
        start += size
    return ranges


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate concurrent Aion transaction load")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--peer-port", type=int, default=7000)
    parser.add_argument("--metrics-port", type=int, default=9000)
    parser.add_argument("--count", type=int, default=1000)
    parser.add_argument("--connections", type=int, default=4)
    parser.add_argument("--amount", type=int, default=1)
    parser.add_argument("--timeout", type=float, default=120.0, help="seconds to wait for node acceptance")
    args = parser.parse_args()
    if args.count <= 0 or args.connections <= 0 or args.amount <= 0:
        parser.error("count, connections, and amount must be positive")

    config = LoadConfig(
        host=args.host,
        peer_port=args.peer_port,
        metrics_port=args.metrics_port,
        count=args.count,
        connections=args.connections,
        amount=args.amount,
    )
    initial_metrics = scrape_metrics(config)
    submitted_before = metric_value(initial_metrics, "aion_transactions_submitted")
    finalized_before = metric_value(initial_metrics, "aion_transactions_finalized")
    started = time.perf_counter()
    with concurrent.futures.ThreadPoolExecutor(max_workers=config.connections) as executor:
        futures = [executor.submit(send_range, config, start, end) for start, end in split_ranges(config.count, config.connections)]
        submitted = sum(future.result() for future in futures)
    client_elapsed = time.perf_counter() - started
    admission_metrics, admission_elapsed = wait_for_metric(
        config, "aion_transactions_submitted", submitted_before + submitted, args.timeout
    )
    final_metrics, finality_elapsed = wait_for_metric(
        config, "aion_transactions_finalized", finalized_before + submitted, args.timeout
    )
    end_to_end_elapsed = time.perf_counter() - started

    print(f"Submitted: {submitted}")
    print(f"Connections: {config.connections}")
    print(f"Client submission seconds: {client_elapsed:.4f}")
    print(f"Client submission TPS: {submitted / client_elapsed:.2f}")
    print(f"Admission seconds: {admission_elapsed:.4f}")
    print(f"Finality seconds: {finality_elapsed:.4f}")
    print(f"Finalized end-to-end TPS: {submitted / end_to_end_elapsed:.2f}")
    print("\nAdmission metrics:")
    print(admission_metrics)
    print("\nFinality metrics:")
    print(final_metrics)


if __name__ == "__main__":
    main()

# aion

**An independent high-performance blockchain built with Zig.**

Aion is an early-stage research and development project focused on building secure, efficient, and scalable decentralized financial infrastructure from the ground up.

> **Important:** Aion is **not production-ready**.  
> Do not entrust any real financial assets or private keys to this software at the current stage.

---

## Vision

The long-term goal of Aion is to create an independent monetary network where users can hold and transfer native digital assets without relying on a centralized payment provider or financial institution to execute transactions.

Aion aims to provide:

- Independent transaction settlement
- Cryptographic ownership of digital assets
- High transaction throughput as a long-term engineering objective
- Secure peer-to-peer communication
- Reliable transaction verification and consensus
- Accessible wallet experiences
- Strong security and operational reliability
- Transparent and verifiable network rules

Aion is **not** a wrapper around an existing blockchain. Its core protocol, ledger, transaction validation, and networking are intended to be independently implemented.

---

## Core Principles

1. **Independence** – The core settlement layer must function without dependence on external financial services.
2. **Security First** – Security is considered throughout development, not added afterwards.
3. **Correctness before performance** – Performance improvements must never compromise transaction correctness or ledger integrity.
4. **Measurable claims** – Throughput and latency numbers must be backed by reproducible benchmarks.
5. **Maintainability** – The codebase must remain understandable and modular as it grows.
6. **Integer monetary arithmetic** – All balances and amounts use integer micro-units. Floating-point arithmetic is forbidden in the settlement path.

---

## Technology

| Component              | Choice                          |
|------------------------|---------------------------------|
| Language               | Zig                             |
| Cryptography           | Ed25519 (via Zig standard library) |
| Ledger model           | Account-based (under review)    |
| Networking             | Custom TCP peer-to-peer         |
| Consensus              | Under research and design       |
| Wallet                 | Non-custodial (planned)         |

---

## Current Status

Aion is in the **research and early implementation** stage.

What currently exists in the repository:

- Core types and integer monetary units
- Account model and state transitions
- Ed25519 key generation, signing and verification
- Transaction structure and basic validation
- Block and chain structures
- Mempool
- Basic networking and node scaffolding
- Early consensus experiments (PoW / BFT related code)
- Metrics and load-testing tools

Many of these components are incomplete, partially tested, or subject to change.  
No consensus mechanism, monetary policy, or production deployment should be considered finalized.

---

## Development Approach

Development follows a strict incremental process:

1. One clearly defined task at a time
2. Tests written alongside implementation
3. Security implications considered before merging
4. Documentation updated with every meaningful change
5. No fabricated performance claims
6. No silent changes to protocol rules

A detailed roadmap and task breakdown is maintained on the project.

---

## Building

Requirements:
- Zig 0.17 or later

```bash
zig build
zig build test
zig build run
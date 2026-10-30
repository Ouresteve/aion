# Aion Codebase Inventory

**Last updated:** 2026-10-30  
**Purpose:** Honest assessment of the current state of every module in the repository.  
This document is a living inventory and should be updated as modules mature or change.

---

## Legend

| Status        | Meaning                                              |
|---------------|------------------------------------------------------|
| Solid         | Core logic is clear and has basic tests              |
| Partial       | Exists and runs, but incomplete or lightly tested    |
| Experimental  | Early implementation, likely to change significantly |
| Scaffolding   | Structure exists, little real logic yet              |
| Missing       | Required by the roadmap but not yet present          |

---

## Core Modules (`src/core/`)

### types.zig
- **Purpose:** Fundamental types (MicroAion, Address, Nonce, etc.)
- **Status:** Solid
- **Notes:** Integer monetary unit is correctly defined. Address is currently raw 32 bytes.
- **Missing / Risks:** Address derivation standard not yet formalized in an ADR.

### account.zig
- **Purpose:** Account structure (balance + nonce) and basic debit/credit operations.
- **Status:** Solid
- **Notes:** Basic overflow and insufficient-funds checks exist.
- **Missing / Risks:** More rigorous overflow testing needed for very large values.

### crypto.zig
- **Purpose:** Ed25519 key generation, signing, and verification.
- **Status:** Partial → Solidifying
- **Notes:** Uses Zig standard library. Key generation now correctly takes `std.Io`.
- **Missing / Risks:** Needs official test vectors and clearer error handling documentation.

### transaction.zig
- **Purpose:** Settlement transaction structure, basic validation, signing and verification.
- **Status:** Partial
- **Notes:** Signing and verification work. Serialization is still simple.
- **Missing / Risks:** Proper versioned binary serialization, fee field, and stronger message-to-sign format.

### state.zig
- **Purpose:** In-memory account state and state transition logic.
- **Status:** Partial
- **Notes:** Can apply signed transactions and update balances/nonces.
- **Missing / Risks:** No persistence yet. Limited concurrency considerations.

### block.zig
- **Purpose:** Block structure and basic validation.
- **Status:** Partial / Experimental
- **Notes:** Structure exists. Hashing and validation logic need careful review.
- **Missing / Risks:** Deterministic hashing must be proven. Merkle roots or equivalent not yet solid.

### chain.zig
- **Purpose:** Chain management, genesis, and block linking.
- **Status:** Partial / Experimental
- **Notes:** Basic chain handling is present.
- **Missing / Risks:** Reorg handling, finality rules, and persistence are incomplete.

### codec.zig
- **Purpose:** Serialization and deserialization of messages and structures.
- **Status:** Partial
- **Notes:** Significant amount of code exists.
- **Missing / Risks:** Must be made fully deterministic and versioned. Needs extensive round-trip tests.

### mempool.zig
- **Purpose:** Pending transaction pool.
- **Status:** Partial
- **Notes:** Basic acceptance and storage logic exists.
- **Missing / Risks:** Nonce ordering, eviction policy, size limits, and DoS resistance need work.

### network.zig + tcp.zig
- **Purpose:** Peer-to-peer networking foundation.
- **Status:** Partial / Experimental
- **Notes:** TCP-based communication scaffolding is present.
- **Missing / Risks:** Framing, peer management, message validation, and resilience are incomplete.

### node.zig
- **Purpose:** Main node orchestration.
- **Status:** Experimental
- **Notes:** Large file that wires many components together.
- **Missing / Risks:** Needs clear separation of concerns and better error isolation.

### service.zig
- **Purpose:** Higher-level node services.
- **Status:** Experimental
- **Notes:** Exists and is sizeable.
- **Missing / Risks:** Responsibilities need clearer documentation.

### http.zig
- **Purpose:** HTTP API surface.
- **Status:** Scaffolding / Early
- **Notes:** Basic HTTP handling present.
- **Missing / Risks:** Authentication, rate limiting, and input validation are not production-grade.

### metrics.zig
- **Purpose:** Internal metrics collection.
- **Status:** Partial
- **Notes:** Useful for later benchmarking.
- **Missing / Risks:** Needs clear definitions of what is being measured.

### pow.zig
- **Purpose:** Proof-of-Work related logic.
- **Status:** Experimental
- **Notes:** Present as an experiment.
- **Missing / Risks:** Consensus mechanism is not yet decided (see future ADR).

### bft.zig
- **Purpose:** Byzantine Fault Tolerance related logic.
- **Status:** Experimental
- **Notes:** Early exploration of BFT ideas.
- **Missing / Risks:** Not a finished consensus implementation.

### validator.zig
- **Purpose:** Transaction / block validation helpers.
- **Status:** Partial
- **Notes:** Supports validation logic.
- **Missing / Risks:** Must be aligned with final validation rules.

### mod.zig
- **Purpose:** Module re-exports.
- **Status:** Solid (structural)
- **Notes:** Clean public interface for the core library.

---

## Entry Points

### src/main.zig
- **Purpose:** Executable entry point.
- **Status:** Partial
- **Notes:** Demonstrates node startup and basic flows.
- **Missing / Risks:** Command-line interface and configuration handling need improvement.

### src/root.zig
- **Purpose:** Library root.
- **Status:** Solid (structural)

---

## Tools

### tools/load_test.py
- **Purpose:** External load testing script.
- **Status:** Experimental
- **Notes:** Useful starting point for later performance work.
- **Missing / Risks:** Results must never be presented as official benchmarks without full environment disclosure.

---

## Summary of Current Maturity

| Area                        | Overall Status     |
|----------------------------|--------------------|
| Cryptographic primitives   | Partial → Solidifying |
| Account & State model      | Partial            |
| Transactions               | Partial            |
| Blocks & Chain             | Experimental       |
| Mempool                    | Partial            |
| Networking                 | Experimental       |
| Consensus                  | Experimental (undecided) |
| Persistence                | Missing            |
| Wallet                     | Missing            |
| Identity / Recovery        | Missing            |
| Production hardening       | Missing            |

---

## Immediate Priorities Emerging from Inventory

1. Formalize Address derivation (ADR)
2. Strengthen transaction serialization
3. Add comprehensive tests for state transitions
4. Decide and document the consensus approach
5. Introduce basic persistence
6. Clean separation between experimental consensus code and core ledger

This inventory will be updated as cards are completed.
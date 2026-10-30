# ADR-0004: Persistence Strategy – Replay-Only

**Date:** 2026-10-31  
**Status:** Accepted  
**Deciders:** Project maintainers

## Context

Aion must be able to restart a node and recover a consistent ledger state.  
Two common approaches exist:

1. **Replay-only** – Persist the canonical chain (blocks). On startup, re-validate and re-apply every transaction to rebuild the in-memory state.
2. **Snapshot + chain** – Persist both the chain and a periodic state snapshot. On startup, load the latest snapshot and replay only the blocks after it.

The project targets high-performance settlement infrastructure. Correctness and a single source of truth are more important than the absolute fastest cold start at this stage.

## Decision

Aion adopts a **Replay-only** persistence strategy for the initial implementation.

- The only durable data is the sequence of finalized blocks.
- Account state is always derived by replaying the chain from genesis.
- No separate state snapshot format is introduced in this phase.

### File layout (v1)

```text
data/
  blocks/
    00000000000000000000.bin   # height 0 (genesis)
    00000000000000000001.bin
    ...
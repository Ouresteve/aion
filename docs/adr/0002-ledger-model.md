# ADR-0002: Ledger Model – Account-Based

**Date:** 2026-10-30  
**Status:** Accepted  
**Deciders:** Project maintainers

## Context

Aion must choose a fundamental ledger model. The two primary options in blockchain design are:

1. **Account-based** (used by Ethereum and many modern chains)
2. **UTXO-based** (used by Bitcoin and its derivatives)

The choice affects:

- Transaction structure
- State representation
- Parallelism potential
- Complexity of light clients
- Ease of implementing high-frequency small-value transfers
- Programming model for future features (escrow, conditional payments, etc.)

Current code in the repository already implements an account-based model (address → balance + nonce).

## Decision

Aion will use an **Account-based ledger model**.

Each account is identified by an address and maintains:

- A balance (in MicroAion – integer only)
- A nonce (to prevent replay attacks)

A transaction debits the sender, credits the recipient, and increments the sender’s nonce.

## Consequences

### Positive
- Natural fit for high-frequency, low-value transfers
- Simple and efficient balance lookups
- Straightforward nonce-based replay protection
- Easier to reason about for programmable settlement features later
- Matches the existing implementation, reducing rewrite cost
- Good performance characteristics for the targeted workload

### Negative
- Global state must be carefully managed
- Parallel execution of transactions that touch the same accounts is more constrained than pure UTXO
- Light-client proofs can be more complex than pure UTXO inclusion proofs
- Requires careful handling of account creation and empty accounts

### Neutral
- The model can later be extended with additional account fields if needed
- Multi-asset support can be added by extending the account structure or using separate balance maps

## Alternatives Considered

- **UTXO model**  
  Rejected for the initial version because it is less natural for the high-frequency small-value settlement use case that Aion targets. Managing many small UTXOs would add complexity and overhead for the intended workload.

- **Hybrid model**  
  Possible in the future, but introduces significant complexity. Not justified at the current stage.

## Implementation Notes

- All balances use `u128` (MicroAion) with strict integer arithmetic.
- Nonce is `u64`.
- Account creation is implicit on first credit.
- Empty accounts may be pruned later as an optimization (not required for correctness).

## References

- Current `src/core/account.zig` and `src/core/state.zig`
- Project vision document – focus on low-value, high-frequency transactions
- Ethereum account model (as prior art, not as dependency)
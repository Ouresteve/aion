# ADR-0005: Initial Consensus Mechanism

**Date:** 2026-10-31  
**Status:** Accepted  
**Deciders:** Project maintainers

## Context

Aion requires a consensus mechanism so that independent nodes can agree on a single, ordered history of blocks and the resulting account state.

The project vision emphasises:

- Independent settlement (no reliance on external chains or custodians)
- Security and correctness before performance claims
- High-frequency, low-value transfers as a long-term engineering goal
- Maintainable, understandable code
- Measurable claims only

The repository already contains two experimental paths:

1. **Proof-of-Work** (`pow.zig`) – classic hash-based mining with a difficulty target.
2. **Simplified BFT** (`bft.zig`, `validator.zig`, parts of `node.zig`) – signed proposals, votes, stake-weighted quorum certificates (> 2/3), and deterministic leader selection by `(height + round) % n`.

Neither path is production-ready. A clear decision is required before further consensus work so that engineering effort is not split indefinitely.

## Decision

Aion adopts a **stake-weighted Byzantine Fault Tolerant (BFT) consensus** as the **initial official consensus mechanism**.

The existing simplified BFT design is taken as the starting point and will be hardened into the first version:

- Fixed validator set (initially configured at genesis / node start)
- Stake-weighted quorum: more than two-thirds of total stake
- Deterministic leader selection: `(height + round) mod validator_count`
- Proposal → votes → Quorum Certificate → finality
- Single-slot finality once a valid QC is obtained (no probabilistic confirmation)

**Proof-of-Work remains in the repository only as an experimental / research module.** It is not part of the official consensus path for the initial network and must not be required for a node to participate in settlement.

## Rationale

### Why BFT for the initial version

| Criterion                         | BFT (chosen)                              | PoW                                      |
|-----------------------------------|-------------------------------------------|------------------------------------------|
| Finality                          | Immediate once QC forms                   | Probabilistic, requires confirmations    |
| Fit for high-frequency settlement | Better (low latency once validators agree)| Higher latency per block                 |
| Energy / resource cost            | Low                                       | High                                     |
| Alignment with current code       | Node already proposes, votes, finalises   | Mining path exists but is secondary      |
| Complexity for small validator set| Manageable                                | Simpler algorithm, harder operational fit|
| Security model                    | Assumes < 1/3 dishonest stake             | Assumes majority honest hash power       |

Aion’s stated goal is a settlement engine, not a permissionless proof-of-work cryptocurrency in the classic sense. Immediate finality and predictable latency are more valuable at this stage than open mining.

### Why keep the design simple

The current BFT code is intentionally minimal:

- No view-change / timeout-driven round advancement yet
- No locked block / prepare-commit phases (HotStuff-style)
- No dynamic validator set changes
- No randomness (VRF) for leader election

This is acceptable for the **first version**. The ADR deliberately chooses a simple, understandable foundation that can be extended later rather than implementing a full production BFT protocol immediately.

## Consequences

### Positive

- Clear direction for all subsequent consensus and networking cards
- Reuses and hardens work already present in `bft.zig`, `validator.zig`, and `node.zig`
- Immediate finality matches the needs of a settlement ledger
- Stake weighting gives a natural path toward later economic security

### Negative / Limitations (explicitly accepted for v1)

- Requires a known validator set (not fully permissionless at launch)
- Leader selection is deterministic and public (no VRF) → easier to target the next leader
- No automatic round advancement on timeout yet → a silent leader can stall progress until manual or future timeout logic intervenes
- No pipeline / concurrent proposals
- Safety under partial synchrony is not yet fully proven in the implementation

These limitations must be documented in every release note and in the security checklist until they are addressed by later ADRs.

### Neutral

- A later ADR may introduce:
  - Timeout-based view change
  - VRF leader election
  - Dynamic validator membership
  - Snapshot + checkpoint optimisations
  - Or a completely different consensus family if the threat model changes

## Alternatives Considered

1. **Pure Proof-of-Work as the official mechanism**  
   Rejected for the initial version because of latency, energy cost, and weaker fit for high-frequency settlement.

2. **Full HotStuff / Tendermint-style protocol immediately**  
   Rejected as too large a jump. The project prefers incremental hardening of the existing simplified BFT with clear tests and ADRs at each step.

3. **Proof-of-Authority with a single sequencer**  
   Rejected because it concentrates too much power and conflicts with the independence principle, even for an early testnet.

4. **Hybrid PoW + BFT**  
   Deferred. Adds complexity before the basic BFT path is solid.

## Implementation Notes (for following cards)

- Official consensus entry points live behind the BFT types (`Proposal`, `Vote`, `QuorumCertificate`, `ValidatorSet`).
- `pow.zig` must remain clearly marked experimental and must not be required by the node binary for normal operation.
- Future cards (networking, propagation, multi-node agreement) build on this decision.
- Any change to the quorum rule, leader election, or finality condition requires a new ADR.

## References

- ADR-0002 (Account-based ledger)
- ADR-0004 (Replay-only persistence)
- `src/core/bft.zig`
- `src/core/validator.zig`
- `src/core/node.zig`
- `src/core/pow.zig` (experimental only)
- Project vision: security first, correctness before performance, independent settlement
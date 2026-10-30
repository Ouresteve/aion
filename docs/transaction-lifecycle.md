# Aion Transaction Lifecycle

**Status:** Draft  
**Last updated:** 2026-10-30  
**Related documents:** ADR-0002 (Ledger Model), token-economics.md

---

## 1. Purpose

This document defines the complete lifecycle of a transaction in Aion from the moment it is created on a user’s device until it is considered final (or rejected).

Every component (wallet, mempool, block production, networking, consensus) must respect this lifecycle.

---

## 2. High-Level Flow

```text
1. Creation
2. Signing
3. Submission
4. Validation (syntactic + semantic)
5. Mempool acceptance
6. Propagation
7. Block inclusion
8. Consensus / Agreement
9. State transition
10. Finality
# Aion Native Token Economics (High-Level)

**Status:** Draft – High-level design only  
**Last updated:** 2026-10-30  
**Related ADRs:** ADR-0002 (Account-based ledger)

---

## 1. Purpose of this Document

This document records the high-level monetary design of Aion.  
It is intentionally limited in scope. Detailed monetary policy, distribution, and governance will be defined in later ADRs once the core ledger is stable.

---

## 2. Native Token

Aion has a single **native utility token** at launch.

- The token is used for transaction fees and as the primary unit of account on the network.
- The token has a **fixed, limited supply**.
- No additional native tokens can be minted after genesis (subject to final monetary policy ADR).

---

## 3. Denomination and Precision

All balances and amounts are expressed in integer **micro-units**.

```text
1 Aion = 1_000_000 MicroAion
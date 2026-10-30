# Aion Security Requirements Checklist

**Status:** Living document  
**Last updated:** 2026-10-30  
**Source:** Project Vision Document – Section 6 (Security Requirements)

This checklist contains the non-negotiable security requirements for Aion.  
Every feature and module must be evaluated against these rules.  
Items are marked with their current compliance status.

---

## Legend

| Status     | Meaning                                      |
|------------|----------------------------------------------|
| ✅ Done    | Fully implemented and tested                 |
| 🟡 Partial | Partially implemented or needs strengthening |
| 🔴 Missing | Not yet implemented                          |
| ⚪ N/A     | Not applicable at current stage              |

---

## 1. Cryptographic Key Handling

| #  | Requirement                                                                 | Status   | Notes |
|----|-----------------------------------------------------------------------------|----------|-------|
| 1.1 | Private keys must be generated using cryptographically secure randomness   | 🟡 Partial | Ed25519 keygen uses Zig’s secure path; needs ongoing audit |
| 1.2 | Users must retain control of their private keys                            | ⚪ N/A   | Wallet not yet implemented |
| 1.3 | Backend administrators must not have unrestricted authority to spend user funds | ⚪ N/A | No custodial backend yet |
| 1.4 | Private keys must never appear in logs, API responses, or ordinary storage | 🟡 Partial | Must be enforced in all future logging and APIs |

---

## 2. Transaction Security

| #  | Requirement                                                                 | Status   | Notes |
|----|-----------------------------------------------------------------------------|----------|-------|
| 2.1 | Transactions must be cryptographically signed                              | ✅ Done  | Ed25519 signatures required |
| 2.2 | Nodes must independently verify transactions                               | ✅ Done  | Validation happens on every node |
| 2.3 | Transaction approvals must be bound to their exact transaction details     | 🟡 Partial | Current message-to-sign is simple; will be strengthened |
| 2.4 | Replay attacks must be prevented                                           | 🟡 Partial | Nonce-based protection exists; needs full chain context |
| 2.5 | Double-spending must be prevented                                          | 🟡 Partial | Nonce + balance checks exist; consensus finality still required |

---

## 3. Network and Input Validation

| #  | Requirement                                                                 | Status   | Notes |
|----|-----------------------------------------------------------------------------|----------|-------|
| 3.1 | Untrusted network messages must be validated                               | 🟡 Partial | Basic validation exists; needs hardening against malformed inputs |
| 3.2 | Malformed or malicious inputs must not crash the node                      | 🟡 Partial | Error handling present but not exhaustively tested |

---

## 4. Operational Security

| #  | Requirement                                                                 | Status   | Notes |
|----|-----------------------------------------------------------------------------|----------|-------|
| 4.1 | Sensitive information must never be written to application logs            | 🟡 Partial | Policy exists; enforcement must be continuous |
| 4.2 | Wallet recovery must not silently weaken cryptographic ownership           | ⚪ N/A   | Recovery design not yet started |
| 4.3 | Security-critical code must have dedicated tests                           | 🟡 Partial | Some tests exist; coverage must increase |
| 4.4 | No production deployment may rely solely on happy-path testing             | ⚪ N/A   | Far from production |

---

## 5. Additional Engineering Rules (Enforced)

- Never invent cryptographic algorithms — only use established, reviewed primitives.
- Never claim the system is secure merely because it uses cryptography.
- Never bypass signature verification for performance.
- Never trust data received from the network without validation.
- Never hard-code private keys or secrets in the repository.

---

## How This Checklist Is Used

1. Before starting a new feature, review the relevant requirements.
2. During implementation, ensure the code satisfies the applicable rules.
3. During review, verify that tests cover the security-critical paths.
4. When a requirement moves from 🔴/🟡 to ✅, update this document and record the date.
5. Any exception to these rules requires an explicit ADR and strong justification.

---

## Next Security-Focused Work

Priority items emerging from this checklist:

1. Strengthen the message that is actually signed (canonical serialization)
2. Add comprehensive tests for invalid signatures, wrong nonces, and insufficient funds
3. Formalize logging policy so private keys can never appear
4. Add explicit tests for malformed network messages
5. Document the threat model more fully in a later card

This checklist will be updated continuously as the project progresses.
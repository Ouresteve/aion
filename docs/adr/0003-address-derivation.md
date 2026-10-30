# ADR-0003: Address Derivation from Public Key

**Date:** 2026-10-30  
**Status:** Accepted  
**Deciders:** Project maintainers

## Context

Every account in Aion is identified by an `Address`.  
An address must be derived deterministically from an Ed25519 public key so that:

- A user who controls a private key can prove ownership of the corresponding address.
- Nodes can reconstruct the public key needed for signature verification from the address alone (under the current model).
- The derivation rule is simple, auditable, and stable.

Several common approaches exist in other blockchains:

- Raw public key (32 bytes)
- Hash of the public key (truncated or full)
- Versioned / checksummed encodings (Base58, Bech32, etc.)
- Nested hashing schemes

## Decision

Aion uses the following rule:

```text
Address = Ed25519 public key bytes (32 bytes raw)
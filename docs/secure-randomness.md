# Secure Randomness Policy – Aion

**Status:** Accepted  
**Last updated:** 2026-10-30  
**Related code:** `src/core/crypto.zig`

---

## 1. Purpose

Cryptographic keys in Aion must be generated with cryptographically secure randomness.  
Weak or predictable randomness would compromise the entire security of the network.

This document defines the only allowed ways to generate key material.

---

## 2. Rules (Non-Negotiable)

1. **Production key generation** must use the secure path:
   ```zig
   crypto.generateKeyPair(io)   // requires a valid std.Io


 
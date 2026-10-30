//! Cryptographic primitives for Aion.
//!
//! This module provides the only approved cryptographic operations for the
//! core protocol:
//!
//! - Ed25519 key generation
//! - Ed25519 signing
//! - Ed25519 signature verification
//! - SHA-256 hashing
//! - Address derivation from public keys
//!
//! Security rules enforced by this module:
//! - Only established primitives from the Zig standard library are used.
//! - Private keys must never be logged or serialized by higher layers.
//! - Verification failures are returned as `false` / errors — never panics.
//! - Deterministic key generation is available for tests only.

const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;

pub const KeyPair = Ed25519.KeyPair;
pub const PublicKey = Ed25519.PublicKey;
pub const SecretKey = Ed25519.SecretKey;
pub const Signature = Ed25519.Signature;

/// 32-byte digest (SHA-256)
pub const Hash = [32]u8;

/// Size of an encoded Ed25519 signature in bytes
pub const signature_length = Signature.encoded_length; // 64

/// Size of a public key / address in bytes
pub const public_key_length = 32;

// ------------------------------------------------------------
// Key generation
// ------------------------------------------------------------

/// Generate a new random key pair using cryptographically secure randomness.
/// Requires a valid `std.Io` (Zig 0.17+).
pub fn generateKeyPair(io: std.Io) KeyPair {
    return Ed25519.KeyPair.generate(io);
}

/// Generate a deterministic key pair from a 32-byte seed.
/// **For tests only.** Never use this for real keys.
pub fn generateKeyPairDeterministic(seed: [32]u8) !KeyPair {
    return try Ed25519.KeyPair.generateDeterministic(seed);
}

// ------------------------------------------------------------
// Signing & Verification
// ------------------------------------------------------------

/// Sign a message with the given key pair.
/// Returns an error if the key pair is inconsistent or signing fails.
pub fn sign(key_pair: KeyPair, message: []const u8) !Signature {
    return try key_pair.sign(message, null);
}

/// Verify a signature over a message.
/// Returns `true` only if the signature is valid for the given public key.
/// Never panics.
pub fn verify(public_key: PublicKey, message: []const u8, signature: Signature) bool {
    signature.verify(message, public_key) catch return false;
    return true;
}

// ------------------------------------------------------------
// Encoding helpers
// ------------------------------------------------------------

/// Encode a signature to its fixed 64-byte representation.
pub fn signatureBytes(signature: Signature) [signature_length]u8 {
    return signature.toBytes();
}

/// Decode a signature from its fixed 64-byte representation.
pub fn signatureFromBytes(bytes: [signature_length]u8) Signature {
    return Signature.fromBytes(bytes);
}

// ------------------------------------------------------------
// Hashing
// ------------------------------------------------------------

/// Compute SHA-256 hash of the input data.
pub fn hash(data: []const u8) Hash {
    var digest: Hash = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    return digest;
}

// ------------------------------------------------------------
// Address derivation
// ------------------------------------------------------------

/// Derive a 32-byte Address directly from an Ed25519 public key.
/// Current rule: Address == raw public key bytes.
/// This decision is recorded in the codebase inventory and will be
/// formalized in a future ADR if the derivation rule changes.
pub fn addressFromPublicKey(public_key: PublicKey) [32]u8 {
    return public_key.bytes;
}

/// Reconstruct a PublicKey from a 32-byte Address.
/// Valid only while Address == raw public key bytes.
pub fn publicKeyFromAddress(address: [32]u8) PublicKey {
    return PublicKey{ .bytes = address };
}

// ------------------------------------------------------------
// Unit tests
// ------------------------------------------------------------

test "key generation produces unique keys" {
    // Deterministic generation for tests
    const kp1 = try generateKeyPairDeterministic(@splat(0x01));
    const kp2 = try generateKeyPairDeterministic(@splat(0x02));

    try std.testing.expect(!std.mem.eql(u8, &kp1.public_key.bytes, &kp2.public_key.bytes));
}

test "sign and verify round-trip" {
    const kp = try generateKeyPairDeterministic(@splat(0x42));
    const message = "aion settlement test message";

    const sig = try sign(kp, message);
    try std.testing.expect(verify(kp.public_key, message, sig));
}

test "verification fails on tampered message" {
    const kp = try generateKeyPairDeterministic(@splat(0x42));
    const message = "original message";
    const sig = try sign(kp, message);

    try std.testing.expect(!verify(kp.public_key, "tampered message", sig));
}

test "verification fails on wrong public key" {
    const kp1 = try generateKeyPairDeterministic(@splat(0x11));
    const kp2 = try generateKeyPairDeterministic(@splat(0x22));
    const message = "message";

    const sig = try sign(kp1, message);
    try std.testing.expect(!verify(kp2.public_key, message, sig));
}

test "address derivation is stable" {
    const kp = try generateKeyPairDeterministic(@splat(0xAB));
    const addr = addressFromPublicKey(kp.public_key);
    const recovered = publicKeyFromAddress(addr);

    try std.testing.expectEqualSlices(u8, &kp.public_key.bytes, &recovered.bytes);
}

test "hash is deterministic" {
    const data = "aion";
    const h1 = hash(data);
    const h2 = hash(data);
    try std.testing.expectEqualSlices(u8, &h1, &h2);
}
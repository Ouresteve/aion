//! Cryptographic test vectors and property tests for Aion’s Ed25519 usage.
//!
//! We verify the properties that matter for protocol safety:
//! - A signature created by a key pair verifies with the matching public key
//! - A tampered message is rejected
//! - A signature is rejected under the wrong public key
//! - Deterministic generation is stable
//!
//! Note: Full RFC 8032 seed→key byte-for-byte vectors depend on the exact
//! seed expansion used by the standard library. We rely on Zig’s own
//! Ed25519 implementation (which is itself tested against the RFC) and
//! focus on the security properties Aion needs.

const std = @import("std");
const crypto = @import("../crypto.zig");

test "sign and verify round-trip" {
    const key_pair = try crypto.generateKeyPairDeterministic(@splat(0x42));
    const message = "Aion settlement engine test vector";

    const signature = try crypto.sign(key_pair, message);
    try std.testing.expect(crypto.verify(key_pair.public_key, message, signature));
}

test "verification fails on tampered message" {
    const key_pair = try crypto.generateKeyPairDeterministic(@splat(0x42));
    const message = "original message";
    const signature = try crypto.sign(key_pair, message);

    try std.testing.expect(!crypto.verify(key_pair.public_key, "tampered message", signature));
}

test "verification fails on wrong public key" {
    const kp1 = try crypto.generateKeyPairDeterministic(@splat(0x11));
    const kp2 = try crypto.generateKeyPairDeterministic(@splat(0x22));
    const message = "important";

    const signature = try crypto.sign(kp1, message);
    try std.testing.expect(!crypto.verify(kp2.public_key, message, signature));
}

test "deterministic generation is stable" {
    const seed: [32]u8 = @splat(0xAB);
    const kp1 = try crypto.generateKeyPairDeterministic(seed);
    const kp2 = try crypto.generateKeyPairDeterministic(seed);

    try std.testing.expectEqualSlices(u8, &kp1.public_key.bytes, &kp2.public_key.bytes);
}

test "different seeds produce different keys" {
    const kp1 = try crypto.generateKeyPairDeterministic(@splat(0x01));
    const kp2 = try crypto.generateKeyPairDeterministic(@splat(0x02));

    try std.testing.expect(!std.mem.eql(u8, &kp1.public_key.bytes, &kp2.public_key.bytes));
}

test "address derivation matches public key bytes" {
    const key_pair = try crypto.generateKeyPairDeterministic(@splat(0xCD));
    const address = crypto.addressFromPublicKey(key_pair.public_key);
    const recovered = crypto.publicKeyFromAddress(address);

    try std.testing.expectEqualSlices(u8, &key_pair.public_key.bytes, &recovered.bytes);
    try std.testing.expectEqualSlices(u8, &key_pair.public_key.bytes, &address);
}

test "empty message can be signed and verified" {
    const key_pair = try crypto.generateKeyPairDeterministic(@splat(0x11));
    const message = "";
    const signature = try crypto.sign(key_pair, message);

    try std.testing.expect(crypto.verify(key_pair.public_key, message, signature));
    try std.testing.expect(!crypto.verify(key_pair.public_key, "x", signature));
}

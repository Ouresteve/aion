//! Cryptographic primitives for Aion.
//! Uses Ed25519 for key generation, signing and verification.

const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;

pub const KeyPair = Ed25519.KeyPair;
pub const PublicKey = Ed25519.PublicKey;
pub const SecretKey = Ed25519.SecretKey;
pub const Signature = Ed25519.Signature;
pub const Hash = [32]u8;

pub fn signatureBytes(signature: Signature) [Signature.encoded_length]u8 {
    return signature.toBytes();
}

pub fn signatureFromBytes(bytes: [Signature.encoded_length]u8) Signature {
    return Signature.fromBytes(bytes);
}

pub fn hash(data: []const u8) Hash {
    var digest: Hash = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    return digest;
}

/// Generate a new random key pair
pub fn generateKeyPair(io: std.Io) KeyPair {
    return Ed25519.KeyPair.generate(io);
}

/// Sign a message using a key pair
pub fn sign(key_pair: KeyPair, message: []const u8) !Signature {
    return try key_pair.sign(message, null);
}

/// Verify a signature
pub fn verify(public_key: PublicKey, message: []const u8, signature: Signature) bool {
    signature.verify(message, public_key) catch return false;
    return true;
}

/// Convert a public key into our Address type (32 bytes)
pub fn addressFromPublicKey(public_key: PublicKey) [32]u8 {
    return public_key.bytes;
}

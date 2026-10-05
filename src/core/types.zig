//! Core primitive types used throughout Aion.
//! All monetary values use strict integer arithmetic.

const std = @import("std");

/// The smallest unit of the native token.
/// 1 Aion = 1_000_000 MicroAion
pub const MicroAion = u128;

/// Helper constant
pub const MICRO_PER_AION: MicroAion = 1_000_000;

/// Account address (32 bytes – will later hold an Ed25519 public key)
pub const Address = [32]u8;

/// Transaction / account nonce to prevent replay attacks
pub const Nonce = u64;

/// SHA-256 digest used for blocks, transactions, and state commitments.
pub const Hash = [32]u8;

/// Unique transaction identifier (will later be a hash)
pub const TxId = [32]u8;

/// Zero address (useful for tests and genesis)
pub const ZERO_ADDRESS: Address = @splat(0);
pub const ZERO_HASH: Hash = @splat(0);

/// Convert whole Aion tokens to MicroAion
pub fn toMicro(amount: u64) MicroAion {
    return @as(MicroAion, amount) * MICRO_PER_AION;
}

/// Simple helper to create an Address from a string (for testing only)
/// In production we will use real public keys.
pub fn addressFromString(input: []const u8) Address {
    var result: Address = ZERO_ADDRESS;
    const len = @min(input.len, 32);
    @memcpy(result[0..len], input[0..len]);
    return result;
}

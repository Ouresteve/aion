//! Proof-of-work consensus primitives.

const std = @import("std");
const block_mod = @import("block.zig");
const types = @import("types.zig");

pub const MAX_DIFFICULTY: u8 = @intCast(@bitSizeOf(types.Hash) / 8);

pub fn meetsDifficulty(hash: types.Hash, difficulty: u8) bool {
    if (difficulty > MAX_DIFFICULTY) return false;
    for (hash[0..difficulty]) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

pub fn mine(block: *block_mod.Block) !void {
    if (block.header.difficulty > MAX_DIFFICULTY) return error.InvalidDifficulty;

    var nonce: u64 = 0;
    while (true) : (nonce += 1) {
        block.header.nonce = nonce;
        block.hash = block.calculateHash();
        if (meetsDifficulty(block.hash, block.header.difficulty)) return;
        if (nonce == std.math.maxInt(u64)) return error.MiningExhausted;
    }
}

test "proof of work mines and validates a block" {
    const allocator = std.testing.allocator;
    var block = try block_mod.Block.init(allocator, 0, types.ZERO_HASH, 1, &.{}, 1);
    defer block.deinit(allocator);

    try mine(&block);
    try std.testing.expect(block.isHashValid());
    try std.testing.expect(meetsDifficulty(block.hash, 1));
}

//! Blocks group signed transactions and commit them to a parent hash.

const std = @import("std");
const crypto = @import("crypto.zig");
const transaction = @import("transaction.zig");
const types = @import("types.zig");

/// Hard protocol limit. It bounds network decoding, state execution, and the
/// work performed while validating an otherwise valid-looking block.
pub const MAX_TRANSACTIONS: usize = 2048;

pub const BlockHeader = struct {
    height: u64,
    previous_hash: types.Hash,
    timestamp: u64,
    transaction_root: types.Hash,
    difficulty: u8,
    nonce: u64,
};

pub const Block = struct {
    header: BlockHeader,
    transactions: []const transaction.SettlementTx,
    hash: types.Hash,

    pub fn init(
        allocator: std.mem.Allocator,
        height: u64,
        previous_hash: types.Hash,
        timestamp: u64,
        transactions: []const transaction.SettlementTx,
        difficulty: u8,
    ) !Block {
        const owned_transactions = try allocator.dupe(transaction.SettlementTx, transactions);
        errdefer allocator.free(owned_transactions);

        var block = Block{
            .header = .{
                .height = height,
                .previous_hash = previous_hash,
                .timestamp = timestamp,
                .transaction_root = try merkleRoot(allocator, owned_transactions),
                .difficulty = difficulty,
                .nonce = 0,
            },
            .transactions = owned_transactions,
            .hash = types.ZERO_HASH,
        };
        block.hash = block.calculateHash();
        return block;
    }

    pub fn deinit(self: *Block, allocator: std.mem.Allocator) void {
        allocator.free(self.transactions);
    }

    pub fn clone(self: Block, allocator: std.mem.Allocator) !Block {
        return .{
            .header = self.header,
            .transactions = try allocator.dupe(transaction.SettlementTx, self.transactions),
            .hash = self.hash,
        };
    }

    pub fn calculateHash(self: Block) types.Hash {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        var encoded: [8]u8 = undefined;
        std.mem.writeInt(u64, &encoded, self.header.height, .little);
        hasher.update(&encoded);
        hasher.update(&self.header.previous_hash);
        std.mem.writeInt(u64, &encoded, self.header.timestamp, .little);
        hasher.update(&encoded);
        hasher.update(&self.header.transaction_root);
        hasher.update(&[_]u8{self.header.difficulty});
        std.mem.writeInt(u64, &encoded, self.header.nonce, .little);
        hasher.update(&encoded);
        var digest: types.Hash = undefined;
        hasher.final(&digest);
        return digest;
    }

    pub fn isHashValid(self: Block) bool {
        return std.mem.eql(u8, &self.hash, &self.calculateHash());
    }
};

pub fn merkleRoot(allocator: std.mem.Allocator, transactions: []const transaction.SettlementTx) !types.Hash {
    if (transactions.len == 0) return types.ZERO_HASH;

    var current = try allocator.alloc(types.Hash, transactions.len);
    defer allocator.free(current);
    var count: usize = transactions.len;
    for (transactions[0..count], 0..) |tx, index| {
        current[index] = tx.hash();
    }

    while (count > 1) {
        var next_count: usize = 0;
        const next = try allocator.alloc(types.Hash, (count + 1) / 2);
        defer allocator.free(next);
        var index: usize = 0;
        while (index < count) : (index += 2) {
            const right = if (index + 1 < count) current[index + 1] else current[index];
            var hasher = std.crypto.hash.sha2.Sha256.init(.{});
            hasher.update(&current[index]);
            hasher.update(&right);
            hasher.final(&next[next_count]);
            next_count += 1;
        }
        @memcpy(current[0..next_count], next[0..next_count]);
        count = next_count;
    }
    return current[0];
}

test "block hash changes when header changes" {
    const allocator = std.testing.allocator;
    var block = try Block.init(allocator, 0, types.ZERO_HASH, 1, &.{}, 0);
    defer block.deinit(allocator);
    try std.testing.expect(block.isHashValid());
    block.header.nonce = 1;
    try std.testing.expect(!block.isHashValid());
}

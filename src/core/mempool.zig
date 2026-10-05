//! Bounded pending-transaction pool for block proposals.

const std = @import("std");
const state_mod = @import("state.zig");
const transaction = @import("transaction.zig");
const types = @import("types.zig");

const NonceKey = struct {
    address: types.Address,
    nonce: types.Nonce,
};

pub const Mempool = struct {
    allocator: std.mem.Allocator,
    capacity: usize,
    transactions: std.AutoHashMap(types.Hash, transaction.SettlementTx),
    nonces: std.AutoHashMap(NonceKey, types.Hash),
    // The count lets us remove an address when its final pending transaction is
    // removed. Keeping a permanent sender set would grow without bound.
    senders: std.AutoHashMap(types.Address, usize),

    pub fn init(allocator: std.mem.Allocator, capacity: usize) Mempool {
        return .{
            .allocator = allocator,
            .capacity = capacity,
            .transactions = std.AutoHashMap(types.Hash, transaction.SettlementTx).init(allocator),
            .nonces = std.AutoHashMap(NonceKey, types.Hash).init(allocator),
            .senders = std.AutoHashMap(types.Address, usize).init(allocator),
        };
    }

    pub fn deinit(self: *Mempool) void {
        self.transactions.deinit();
        self.nonces.deinit();
        self.senders.deinit();
    }

    pub fn count(self: *const Mempool) usize {
        return self.transactions.count();
    }

    pub fn add(self: *Mempool, state: *const state_mod.State, tx: transaction.SettlementTx) !types.Hash {
        if (self.transactions.count() >= self.capacity) return error.MempoolFull;
        try tx.validateBasic();
        if (!tx.verify()) return error.InvalidSignature;

        const id = tx.hash();
        if (self.transactions.contains(id)) return error.DuplicateTransaction;

        const current_nonce = if (state.get(tx.from)) |account| account.nonce else 0;
        if (tx.nonce < current_nonce) return error.StaleNonce;

        const nonce_key = NonceKey{ .address = tx.from, .nonce = tx.nonce };
        if (self.nonces.contains(nonce_key)) return error.DuplicateNonce;

        try self.transactions.put(id, tx);
        errdefer _ = self.transactions.remove(id);
        try self.nonces.put(nonce_key, id);
        errdefer _ = self.nonces.remove(nonce_key);

        const sender_entry = try self.senders.getOrPut(tx.from);
        if (sender_entry.found_existing) {
            sender_entry.value_ptr.* = std.math.add(usize, sender_entry.value_ptr.*, 1) catch {
                return error.SenderTransactionCountOverflow;
            };
        } else {
            sender_entry.value_ptr.* = 1;
        }
        return id;
    }

    pub fn remove(self: *Mempool, id: types.Hash) bool {
        const tx = self.transactions.get(id) orelse return false;
        _ = self.transactions.remove(id);
        _ = self.nonces.remove(.{ .address = tx.from, .nonce = tx.nonce });
        if (self.senders.getPtr(tx.from)) |sender_count| {
            if (sender_count.* == 1) {
                _ = self.senders.remove(tx.from);
            } else {
                sender_count.* -= 1;
            }
        }
        return true;
    }

    pub fn removeIncluded(self: *Mempool, selected: []const transaction.SettlementTx) void {
        for (selected) |tx| _ = self.remove(tx.hash());
    }

    /// Select executable transactions in deterministic sender/nonce order.
    /// The temporary state prevents overspending and nonce gaps in a proposal.
    pub fn selectForBlock(
        self: *const Mempool,
        allocator: std.mem.Allocator,
        state: *const state_mod.State,
        limit: usize,
    ) ![]transaction.SettlementTx {
        var working_state = try state.clone();
        defer working_state.deinit();

        var selected = std.ArrayList(transaction.SettlementTx).empty;
        errdefer selected.deinit(allocator);

        while (selected.items.len < limit) {
            var best: ?transaction.SettlementTx = null;
            var best_id: types.Hash = undefined;
            var iterator = self.senders.iterator();
            while (iterator.next()) |entry| {
                const sender = entry.key_ptr.*;
                const account = working_state.get(sender);
                const expected_nonce = if (account) |value| value.nonce else 0;
                const id = self.nonces.get(.{ .address = sender, .nonce = expected_nonce }) orelse continue;
                const candidate = self.transactions.get(id) orelse continue;
                if (account == null or !account.?.canAfford(candidate.amount)) continue;

                if (best == null or std.mem.order(u8, entry.key_ptr, &best_id) == .lt) {
                    best = candidate;
                    best_id = entry.key_ptr.*;
                }
            }

            const next = best orelse break;
            try working_state.applyValidatedTransaction(next);
            try selected.append(allocator, next);
        }

        return try selected.toOwnedSlice(allocator);
    }
};

test "mempool validates, deduplicates, and orders executable transactions" {
    const allocator = std.testing.allocator;
    const sender_keys = try @import("crypto.zig").KeyPair.generateDeterministic(@splat(0x51));
    const receiver_keys = try @import("crypto.zig").KeyPair.generateDeterministic(@splat(0x52));
    const sender = @import("crypto.zig").addressFromPublicKey(sender_keys.public_key);
    const receiver = @import("crypto.zig").addressFromPublicKey(receiver_keys.public_key);

    var state = state_mod.State.init(allocator);
    defer state.deinit();
    (try state.getOrCreate(sender)).balance = 100;

    var mempool = Mempool.init(allocator, 8);
    defer mempool.deinit();

    var second = transaction.SettlementTx{ .from = sender, .to = receiver, .amount = 30, .nonce = 1 };
    try second.sign(sender_keys);
    _ = try mempool.add(&state, second);

    var first = transaction.SettlementTx{ .from = sender, .to = receiver, .amount = 30, .nonce = 0 };
    try first.sign(sender_keys);
    const first_id = try mempool.add(&state, first);

    try std.testing.expectError(error.DuplicateTransaction, mempool.add(&state, first));
    try std.testing.expectEqual(@as(usize, 2), mempool.count());

    const selected = try mempool.selectForBlock(allocator, &state, 2);
    defer allocator.free(selected);
    try std.testing.expectEqual(@as(usize, 2), selected.len);
    try std.testing.expectEqual(@as(u64, 0), selected[0].nonce);
    try std.testing.expectEqual(@as(u64, 1), selected[1].nonce);

    mempool.removeIncluded(selected);
    try std.testing.expect(!mempool.remove(first_id));
    try std.testing.expectEqual(@as(usize, 0), mempool.count());
    try std.testing.expectEqual(@as(usize, 0), mempool.senders.count());
}

//! In-memory account state.
//! This is the current source of truth for balances and nonces.

const std = @import("std");
const types = @import("types.zig");
const account = @import("account.zig");
const transaction = @import("transaction.zig");

pub const State = struct {
    accounts: std.AutoHashMap(types.Address, account.Account),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) State {
        return State{
            .accounts = std.AutoHashMap(types.Address, account.Account).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *State) void {
        self.accounts.deinit();
    }

    pub fn getOrCreate(self: *State, address: types.Address) !*account.Account {
        const result = try self.accounts.getOrPut(address);
        if (!result.found_existing) {
            result.value_ptr.* = account.Account.init();
        }
        return result.value_ptr;
    }

    pub fn get(self: *const State, address: types.Address) ?account.Account {
        return self.accounts.get(address);
    }

    pub fn clone(self: *const State) !State {
        var copy = State.init(self.allocator);
        errdefer copy.deinit();

        var iterator = self.accounts.iterator();
        while (iterator.next()) |entry| {
            try copy.accounts.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        return copy;
    }

    /// Apply a settlement transaction (the core state transition)
    pub fn applyTransaction(self: *State, tx: transaction.SettlementTx) !void {
        // 1. Basic validation
        try tx.validateBasic();

        // 2. Verify cryptographic signature
        if (!tx.verify()) {
            return error.InvalidSignature;
        }

        try self.applyValidatedTransaction(tx);
    }

    /// Apply a transaction whose signature and basic form were already checked.
    /// Mempool selection uses this to avoid verifying the same signature twice.
    pub fn applyValidatedTransaction(self: *State, tx: transaction.SettlementTx) !void {

        // Ensure both entries exist before taking pointers into the hash map.
        _ = try self.getOrCreate(tx.from);
        _ = try self.getOrCreate(tx.to);

        const sender = self.accounts.getPtr(tx.from).?;

        // 4. Check nonce
        if (tx.nonce != sender.nonce) {
            return error.InvalidNonce;
        }

        // 5. Check balance
        if (!sender.canAfford(tx.amount)) {
            return error.InsufficientFunds;
        }

        const recipient = self.accounts.getPtr(tx.to).?;

        // Establish that every mutation below can complete before changing either
        // account. A failed transfer must never partially debit the sender.
        if (recipient.balance > std.math.maxInt(types.MicroAion) - tx.amount) {
            return error.BalanceOverflow;
        }
        if (sender.nonce == std.math.maxInt(types.Nonce)) {
            return error.NonceOverflow;
        }

        // 7. Perform the state transition
        try sender.debit(tx.amount);
        try recipient.credit(tx.amount);
        try sender.incrementNonce();
    }

    pub fn applyTransactionsAtomic(self: *State, transactions: []const transaction.SettlementTx) !void {
        var snapshots = std.AutoHashMap(types.Address, ?account.Account).init(self.allocator);
        defer snapshots.deinit();
        var committed = false;
        defer {
            if (!committed) self.rollback(&snapshots);
        }

        for (transactions) |tx| {
            try self.snapshot(&snapshots, tx.from);
            try self.snapshot(&snapshots, tx.to);
            try self.applyTransaction(tx);
        }
        committed = true;
    }

    fn snapshot(self: *State, snapshots: *std.AutoHashMap(types.Address, ?account.Account), address: types.Address) !void {
        if (!snapshots.contains(address)) {
            try snapshots.put(address, self.accounts.get(address));
        }
    }

    fn rollback(self: *State, snapshots: *std.AutoHashMap(types.Address, ?account.Account)) void {
        var iterator = snapshots.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.*) |original| {
                if (self.accounts.getPtr(entry.key_ptr.*)) |current| {
                    current.* = original;
                } else {
                    self.accounts.put(entry.key_ptr.*, original) catch unreachable;
                }
            } else {
                _ = self.accounts.remove(entry.key_ptr.*);
            }
        }
    }
};

test "atomic state application rolls back earlier transactions on failure" {
    const allocator = std.testing.allocator;
    const sender_keys = try @import("crypto.zig").KeyPair.generateDeterministic(@splat(0x91));
    const receiver_keys = try @import("crypto.zig").KeyPair.generateDeterministic(@splat(0x92));
    const sender = @import("crypto.zig").addressFromPublicKey(sender_keys.public_key);
    const receiver = @import("crypto.zig").addressFromPublicKey(receiver_keys.public_key);

    var state = State.init(allocator);
    defer state.deinit();
    (try state.getOrCreate(sender)).balance = 100;

    var first = transaction.SettlementTx{ .from = sender, .to = receiver, .amount = 60, .nonce = 0 };
    var second = transaction.SettlementTx{ .from = sender, .to = receiver, .amount = 60, .nonce = 1 };
    try first.sign(sender_keys);
    try second.sign(sender_keys);

    try std.testing.expectError(error.InsufficientFunds, state.applyTransactionsAtomic(&.{ first, second }));
    try std.testing.expectEqual(@as(u128, 100), state.get(sender).?.balance);
    try std.testing.expectEqual(@as(u64, 0), state.get(sender).?.nonce);
    try std.testing.expect(state.get(receiver) == null);
}

test "a balance overflow leaves both accounts unchanged" {
    const allocator = std.testing.allocator;
    const sender_keys = try @import("crypto.zig").KeyPair.generateDeterministic(@splat(0xA1));
    const receiver_keys = try @import("crypto.zig").KeyPair.generateDeterministic(@splat(0xA2));
    const sender = @import("crypto.zig").addressFromPublicKey(sender_keys.public_key);
    const receiver = @import("crypto.zig").addressFromPublicKey(receiver_keys.public_key);

    var state = State.init(allocator);
    defer state.deinit();
    (try state.getOrCreate(sender)).balance = 1;
    (try state.getOrCreate(receiver)).balance = std.math.maxInt(types.MicroAion);

    var tx = transaction.SettlementTx{ .from = sender, .to = receiver, .amount = 1, .nonce = 0 };
    try tx.sign(sender_keys);

    try std.testing.expectError(error.BalanceOverflow, state.applyTransaction(tx));
    try std.testing.expectEqual(@as(types.MicroAion, 1), state.get(sender).?.balance);
    try std.testing.expectEqual(@as(types.Nonce, 0), state.get(sender).?.nonce);
    try std.testing.expectEqual(std.math.maxInt(types.MicroAion), state.get(receiver).?.balance);
}

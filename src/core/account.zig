//! Account state representation.
//! Every account holds a balance and a nonce.

const std = @import("std");
const types = @import("types.zig");

pub const Account = struct {
    balance: types.MicroAion = 0,
    nonce: types.Nonce = 0,

    /// Create a new empty account
    pub fn init() Account {
        return Account{};
    }

    /// Create an account with an initial balance
    pub fn initWithBalance(balance: types.MicroAion) Account {
        return Account{
            .balance = balance,
            .nonce = 0,
        };
    }

    /// Check whether the account can afford a debit
    pub fn canAfford(self: Account, amount: types.MicroAion) bool {
        return self.balance >= amount;
    }

    /// Safely debit the account.
    /// Returns an error if there are insufficient funds.
    pub fn debit(self: *Account, amount: types.MicroAion) !void {
        if (amount > self.balance) {
            return error.InsufficientFunds;
        }
        self.balance -= amount;
    }

    /// Credit the account without allowing its balance to wrap.
    pub fn credit(self: *Account, amount: types.MicroAion) !void {
        self.balance = std.math.add(types.MicroAion, self.balance, amount) catch {
            return error.BalanceOverflow;
        };
    }

    /// Increment the nonce (used after a successful transaction)
    pub fn incrementNonce(self: *Account) !void {
        self.nonce = std.math.add(types.Nonce, self.nonce, 1) catch {
            return error.NonceOverflow;
        };
    }
};

test "debit fails on insufficient funds" {
    var acc = Account.initWithBalance(50);
    try std.testing.expectError(error.InsufficientFunds, acc.debit(51));
    try std.testing.expect(acc.balance == 50);
}

test "debit succeeds when funds are exact" {
    var acc = Account.initWithBalance(50);
    try acc.debit(50);
    try std.testing.expect(acc.balance == 0);
}

test "credit detects balance overflow" {
    var acc = Account.initWithBalance(std.math.maxInt(types.MicroAion));
    try std.testing.expectError(error.BalanceOverflow, acc.credit(1));
}

test "nonce overflow is detected" {
    var acc = Account{ .balance = 0, .nonce = std.math.maxInt(types.Nonce) };
    try std.testing.expectError(error.NonceOverflow, acc.incrementNonce());
}

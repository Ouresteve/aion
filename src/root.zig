//! Aion Settlement Engine
//! Production-ready multi-node settlement engine for low-value, high-frequency transactions.

const std = @import("std");

pub const core = @import("core/mod.zig");

pub const version = "0.1.0";

pub fn hello() []const u8 {
    return "Aion Settlement Engine – Core types + State loaded";
}

test "full state transition works" {
    const allocator = std.testing.allocator;

    // For tests we still need an Io. In 0.17 the testing allocator path is simpler,
    // so we use a deterministic key for the test.
    var seed: [32]u8 = undefined;
    @memset(&seed, 0x42); // deterministic seed for tests

    const alice_keys = try core.KeyPair.generateDeterministic(seed);
    const bob_keys = try core.KeyPair.generateDeterministic(@splat(0x24));

    const alice = core.addressFromPublicKey(alice_keys.public_key);
    const bob = core.addressFromPublicKey(bob_keys.public_key);

    var state = core.State.init(allocator);
    defer state.deinit();

    // Fund Alice
    const alice_acc = try state.getOrCreate(alice);
    alice_acc.balance = core.toMicro(1000);

    // Create and sign a transaction
    var tx = core.SettlementTx{
        .from = alice,
        .to = bob,
        .amount = core.toMicro(150),
        .nonce = 0,
    };
    try tx.sign(alice_keys);

    // Apply the transaction
    try state.applyTransaction(tx);

    // Verify results
    const alice_after = state.get(alice).?;
    const bob_after = state.get(bob).?;

    try std.testing.expect(alice_after.balance == core.toMicro(850));
    try std.testing.expect(alice_after.nonce == 1);
    try std.testing.expect(bob_after.balance == core.toMicro(150));
    try std.testing.expect(bob_after.nonce == 0);
}

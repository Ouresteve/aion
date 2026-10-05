//! Canonical chain storage and block/state validation.

const std = @import("std");
const bft = @import("bft.zig");
const block_mod = @import("block.zig");
const pow = @import("pow.zig");
const state_mod = @import("state.zig");
const types = @import("types.zig");
const validator_mod = @import("validator.zig");

pub const Chain = struct {
    allocator: std.mem.Allocator,
    blocks: []block_mod.Block,
    state: state_mod.State,

    pub fn init(allocator: std.mem.Allocator, timestamp: u64) !Chain {
        var genesis = try block_mod.Block.init(allocator, 0, types.ZERO_HASH, timestamp, &.{}, 0);
        errdefer genesis.deinit(allocator);

        var blocks = try allocator.alloc(block_mod.Block, 1);
        blocks[0] = genesis;
        return .{
            .allocator = allocator,
            .blocks = blocks,
            .state = state_mod.State.init(allocator),
        };
    }

    pub fn deinit(self: *Chain) void {
        for (self.blocks) |*block| block.deinit(self.allocator);
        self.allocator.free(self.blocks);
        self.state.deinit();
    }

    pub fn height(self: *const Chain) u64 {
        return self.blocks[self.blocks.len - 1].header.height;
    }

    pub fn tip(self: *const Chain) *const block_mod.Block {
        return &self.blocks[self.blocks.len - 1];
    }

    pub fn produceProofOfWorkBlock(
        self: *Chain,
        timestamp: u64,
        transactions: []const @import("transaction.zig").SettlementTx,
        difficulty: u8,
    ) !void {
        var candidate = try block_mod.Block.init(
            self.allocator,
            self.height() + 1,
            self.tip().hash,
            timestamp,
            transactions,
            difficulty,
        );
        defer candidate.deinit(self.allocator);

        try pow.mine(&candidate);
        try self.appendProofOfWork(candidate);
    }

    pub fn appendProofOfWork(self: *Chain, candidate: block_mod.Block) !void {
        try self.validateCandidate(candidate);
        if (!pow.meetsDifficulty(candidate.hash, candidate.header.difficulty)) {
            return error.InsufficientProofOfWork;
        }
        try self.commitCandidate(candidate);
    }

    pub fn appendFinalized(
        self: *Chain,
        candidate: block_mod.Block,
        proposal: bft.Proposal,
        certificate: bft.QuorumCertificate,
        validators: validator_mod.ValidatorSet,
    ) !void {
        if (candidate.header.difficulty != 0) return error.InvalidBftDifficulty;
        try self.validateCandidate(candidate);
        if (proposal.height != candidate.header.height or proposal.round != certificate.round) {
            return error.InvalidProposal;
        }
        if (!std.mem.eql(u8, &proposal.block_hash, &candidate.hash)) return error.InvalidProposal;
        if (!proposal.verify(validators)) return error.InvalidProposal;
        if (certificate.height != candidate.header.height) return error.InvalidCertificateHeight;
        if (!std.mem.eql(u8, &certificate.block_hash, &candidate.hash)) {
            return error.InvalidCertificateBlock;
        }
        if (!certificate.verify(validators)) return error.InvalidQuorumCertificate;
        try self.commitCandidate(candidate);
    }

    fn validateCandidate(self: *const Chain, candidate: block_mod.Block) !void {
        const parent = self.tip();
        if (candidate.header.height != parent.header.height + 1) {
            return error.InvalidHeight;
        }
        if (!std.mem.eql(u8, &candidate.header.previous_hash, &parent.hash)) {
            return error.InvalidParent;
        }
        if (candidate.header.timestamp < parent.header.timestamp) {
            return error.InvalidTimestamp;
        }
        if (candidate.transactions.len > block_mod.MAX_TRANSACTIONS) {
            return error.BlockTooLarge;
        }
        if (!candidate.isHashValid()) return error.InvalidBlockHash;
        const expected_root = try block_mod.merkleRoot(self.allocator, candidate.transactions);
        if (!std.mem.eql(u8, &candidate.header.transaction_root, &expected_root)) {
            return error.InvalidTransactionRoot;
        }
    }

    fn commitCandidate(self: *Chain, candidate: block_mod.Block) !void {
        // Execute against an isolated state copy before changing the canonical
        // chain. This makes block/state commitment all-or-nothing even when a
        // transaction fails validation or allocation fails during the transition.
        var next_state = try self.state.clone();
        errdefer next_state.deinit();
        try next_state.applyTransactionsAtomic(candidate.transactions);

        var stored = try cloneBlock(self.allocator, candidate);
        errdefer stored.deinit(self.allocator);
        const old_length = self.blocks.len;
        const resized = try self.allocator.realloc(self.blocks, self.blocks.len + 1);
        self.blocks = resized;
        self.blocks[old_length] = stored;
        self.state.deinit();
        self.state = next_state;
    }
};

fn cloneBlock(allocator: std.mem.Allocator, source: block_mod.Block) !block_mod.Block {
    return source.clone(allocator);
}

test "chain appends a valid block and commits state atomically" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, 1);
    defer chain.deinit();

    const sender_keys = try @import("crypto.zig").KeyPair.generateDeterministic(@splat(0x11));
    const receiver_keys = try @import("crypto.zig").KeyPair.generateDeterministic(@splat(0x22));
    const sender = @import("crypto.zig").addressFromPublicKey(sender_keys.public_key);
    const receiver = @import("crypto.zig").addressFromPublicKey(receiver_keys.public_key);
    (try chain.state.getOrCreate(sender)).balance = 100;

    var tx = @import("transaction.zig").SettlementTx{
        .from = sender,
        .to = receiver,
        .amount = 40,
        .nonce = 0,
    };
    try tx.sign(sender_keys);
    var candidate = try block_mod.Block.init(allocator, 1, chain.tip().hash, 2, &.{tx}, 1);
    defer candidate.deinit(allocator);
    try pow.mine(&candidate);
    const mined_hash = candidate.hash;
    const mined_nonce = candidate.header.nonce;

    try chain.appendProofOfWork(candidate);
    try std.testing.expectEqual(mined_hash, chain.tip().hash);
    try std.testing.expectEqual(mined_nonce, chain.tip().header.nonce);
    try std.testing.expectEqual(@as(u128, 60), chain.state.get(sender).?.balance);
    try std.testing.expectEqual(@as(u128, 40), chain.state.get(receiver).?.balance);
}

test "chain commits a block finalized by a BFT quorum" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, 1);
    defer chain.deinit();

    const first = try @import("crypto.zig").KeyPair.generateDeterministic(@splat(0x31));
    const second = try @import("crypto.zig").KeyPair.generateDeterministic(@splat(0x32));
    const receiver_keys = try @import("crypto.zig").KeyPair.generateDeterministic(@splat(0x33));
    const first_address = @import("crypto.zig").addressFromPublicKey(first.public_key);
    const second_address = @import("crypto.zig").addressFromPublicKey(second.public_key);
    const receiver = @import("crypto.zig").addressFromPublicKey(receiver_keys.public_key);
    var validators = try validator_mod.ValidatorSet.init(allocator, &.{
        .{ .address = first_address, .stake = 50 },
        .{ .address = second_address, .stake = 30 },
    });
    defer validators.deinit();

    (try chain.state.getOrCreate(first_address)).balance = 100;
    var tx = @import("transaction.zig").SettlementTx{
        .from = first_address,
        .to = receiver,
        .amount = 40,
        .nonce = 0,
    };
    try tx.sign(first);
    var candidate = try block_mod.Block.init(allocator, 1, chain.tip().hash, 2, &.{tx}, 0);
    defer candidate.deinit(allocator);

    var proposal = bft.Proposal{
        .height = 1,
        .round = 0,
        .block_hash = candidate.hash,
        .proposer = first_address,
        .signature = undefined,
    };
    try proposal.sign(first);

    var first_vote = bft.Vote{
        .height = 1,
        .round = 0,
        .block_hash = candidate.hash,
        .voter = first_address,
        .signature = undefined,
    };
    var second_vote = bft.Vote{
        .height = 1,
        .round = 0,
        .block_hash = candidate.hash,
        .voter = second_address,
        .signature = undefined,
    };
    try first_vote.sign(first);
    try second_vote.sign(second);
    var certificate = try bft.QuorumCertificate.init(allocator, 1, 0, candidate.hash, &.{ first_vote, second_vote });
    defer certificate.deinit();

    try chain.appendFinalized(candidate, proposal, certificate, validators);
    try std.testing.expectEqual(@as(u128, 60), chain.state.get(first_address).?.balance);
    try std.testing.expectEqual(@as(u128, 40), chain.state.get(receiver).?.balance);
}

test "a rejected block leaves the canonical chain and ledger untouched" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, 10);
    defer chain.deinit();

    const sender_keys = try @import("crypto.zig").KeyPair.generateDeterministic(@splat(0xB1));
    const receiver_keys = try @import("crypto.zig").KeyPair.generateDeterministic(@splat(0xB2));
    const sender = @import("crypto.zig").addressFromPublicKey(sender_keys.public_key);
    const receiver = @import("crypto.zig").addressFromPublicKey(receiver_keys.public_key);
    (try chain.state.getOrCreate(sender)).balance = 1;
    const genesis_hash = chain.tip().hash;

    var tx = @import("transaction.zig").SettlementTx{
        .from = sender,
        .to = receiver,
        .amount = 2,
        .nonce = 0,
    };
    try tx.sign(sender_keys);
    var candidate = try block_mod.Block.init(allocator, 1, genesis_hash, 11, &.{tx}, 0);
    defer candidate.deinit(allocator);

    try std.testing.expectError(error.InsufficientFunds, chain.appendProofOfWork(candidate));
    try std.testing.expectEqual(@as(u64, 0), chain.height());
    try std.testing.expectEqual(genesis_hash, chain.tip().hash);
    try std.testing.expectEqual(@as(types.MicroAion, 1), chain.state.get(sender).?.balance);
    try std.testing.expect(chain.state.get(receiver) == null);
}

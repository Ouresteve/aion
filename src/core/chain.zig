//! Canonical chain storage and block/state validation.
//!
//! Consensus path is stake-weighted BFT only (ADR-0005).
//! When a Storage is supplied the chain becomes durable:
//! - Every successfully committed block is written to disk.
//! - On startup the chain can be rebuilt by replaying the stored blocks.
//! State is never stored; it is always derived (ADR-0004).

const std = @import("std");
const bft = @import("bft.zig");
const block_mod = @import("block.zig");
const state_mod = @import("state.zig");
const storage_mod = @import("storage.zig");
const types = @import("types.zig");
const validator_mod = @import("validator.zig");

pub const Chain = struct {
    allocator: std.mem.Allocator,
    blocks: []block_mod.Block,
    state: state_mod.State,
    /// Optional durable storage. When non-null, every committed block is persisted.
    storage: ?*storage_mod.Storage = null,

    /// Create a fresh in-memory chain with a genesis block.
    pub fn init(allocator: std.mem.Allocator, timestamp: u64) !Chain {
        var genesis = try block_mod.Block.init(allocator, 0, types.ZERO_HASH, timestamp, &.{}, 0);
        errdefer genesis.deinit(allocator);

        var blocks = try allocator.alloc(block_mod.Block, 1);
        blocks[0] = genesis;
        return .{
            .allocator = allocator,
            .blocks = blocks,
            .state = state_mod.State.init(allocator),
            .storage = null,
        };
    }

    /// Create a chain backed by durable storage (replay-only recovery).
    pub fn initWithStorage(
        allocator: std.mem.Allocator,
        storage: *storage_mod.Storage,
        genesis_timestamp: u64,
    ) !Chain {
        const loaded = try storage.loadAllBlocks();
        errdefer {
            for (loaded) |*b| b.deinit(allocator);
            allocator.free(loaded);
        }

        if (loaded.len == 0) {
            var chain = try Chain.init(allocator, genesis_timestamp);
            chain.storage = storage;
            try storage.saveBlock(chain.blocks[0]);
            return chain;
        }

        if (loaded[0].header.height != 0) {
            for (loaded) |*b| b.deinit(allocator);
            allocator.free(loaded);
            return error.MissingGenesis;
        }

        var state = state_mod.State.init(allocator);
        errdefer state.deinit();

        for (loaded[1..]) |block| {
            try state.applyTransactionsAtomic(block.transactions);
        }

        return .{
            .allocator = allocator,
            .blocks = loaded,
            .state = state,
            .storage = storage,
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

    /// Commit a block that carries a valid BFT proposal and quorum certificate.
    pub fn appendFinalized(
        self: *Chain,
        candidate: block_mod.Block,
        proposal: bft.Proposal,
        certificate: bft.QuorumCertificate,
        validators: validator_mod.ValidatorSet,
    ) !void {
        // BFT blocks must not carry a PoW difficulty.
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
        var next_state = try self.state.clone();
        errdefer next_state.deinit();
        try next_state.applyTransactionsAtomic(candidate.transactions);

        var stored = try cloneBlock(self.allocator, candidate);
        errdefer stored.deinit(self.allocator);

        // Persist before mutating in-memory chain (crash recovery stays consistent).
        if (self.storage) |storage| {
            try storage.saveBlock(stored);
        }

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

// ---------------------------------------------------------------------------
// Helpers used only by tests
// ---------------------------------------------------------------------------

fn testKeyPair(seed: u8) !@import("crypto.zig").KeyPair {
    return @import("crypto.zig").KeyPair.generateDeterministic(@splat(seed));
}

fn testAddress(seed: u8) !types.Address {
    const kp = try testKeyPair(seed);
    return @import("crypto.zig").addressFromPublicKey(kp.public_key);
}

fn signProposal(
    height: u64,
    round: u64,
    block_hash: types.Hash,
    proposer: types.Address,
    keys: @import("crypto.zig").KeyPair,
) !bft.Proposal {
    var proposal = bft.Proposal{
        .height = height,
        .round = round,
        .block_hash = block_hash,
        .proposer = proposer,
        .signature = undefined,
    };
    try proposal.sign(keys);
    return proposal;
}

fn signVote(
    height: u64,
    round: u64,
    block_hash: types.Hash,
    voter: types.Address,
    keys: @import("crypto.zig").KeyPair,
) !bft.Vote {
    var vote = bft.Vote{
        .height = height,
        .round = round,
        .block_hash = block_hash,
        .voter = voter,
        .signature = undefined,
    };
    try vote.sign(keys);
    return vote;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "chain commits a block finalized by a BFT quorum" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, 1);
    defer chain.deinit();

    const first_keys = try testKeyPair(0x31);
    const second_keys = try testKeyPair(0x32);
    const receiver_keys = try testKeyPair(0x33);
    const first_address = @import("crypto.zig").addressFromPublicKey(first_keys.public_key);
    const second_address = @import("crypto.zig").addressFromPublicKey(second_keys.public_key);
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
    try tx.sign(first_keys);

    // difficulty = 0 (BFT)
    var candidate = try block_mod.Block.init(allocator, 1, chain.tip().hash, 2, &.{tx}, 0);
    defer candidate.deinit(allocator);

    const proposal = try signProposal(1, 0, candidate.hash, first_address, first_keys);
    const v1 = try signVote(1, 0, candidate.hash, first_address, first_keys);
    const v2 = try signVote(1, 0, candidate.hash, second_address, second_keys);
    var certificate = try bft.QuorumCertificate.init(allocator, 1, 0, candidate.hash, &.{ v1, v2 });
    defer certificate.deinit();

    try chain.appendFinalized(candidate, proposal, certificate, validators);
    try std.testing.expectEqual(@as(u128, 60), chain.state.get(first_address).?.balance);
    try std.testing.expectEqual(@as(u128, 40), chain.state.get(receiver).?.balance);
    try std.testing.expectEqual(@as(u64, 1), chain.height());
}

test "a rejected block leaves the canonical chain and ledger untouched" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, 10);
    defer chain.deinit();

    const sender_keys = try testKeyPair(0xB1);
    const receiver_keys = try testKeyPair(0xB2);
    const sender = @import("crypto.zig").addressFromPublicKey(sender_keys.public_key);
    const receiver = @import("crypto.zig").addressFromPublicKey(receiver_keys.public_key);

    var validators = try validator_mod.ValidatorSet.init(allocator, &.{
        .{ .address = sender, .stake = 100 },
    });
    defer validators.deinit();

    (try chain.state.getOrCreate(sender)).balance = 1;
    const genesis_hash = chain.tip().hash;

    var tx = @import("transaction.zig").SettlementTx{
        .from = sender,
        .to = receiver,
        .amount = 2, // more than balance
        .nonce = 0,
    };
    try tx.sign(sender_keys);

    var candidate = try block_mod.Block.init(allocator, 1, genesis_hash, 11, &.{tx}, 0);
    defer candidate.deinit(allocator);

    const proposal = try signProposal(1, 0, candidate.hash, sender, sender_keys);
    const vote = try signVote(1, 0, candidate.hash, sender, sender_keys);
    var certificate = try bft.QuorumCertificate.init(allocator, 1, 0, candidate.hash, &.{vote});
    defer certificate.deinit();

    try std.testing.expectError(error.InsufficientFunds, chain.appendFinalized(candidate, proposal, certificate, validators));
    try std.testing.expectEqual(@as(u64, 0), chain.height());
    try std.testing.expectEqual(genesis_hash, chain.tip().hash);
    try std.testing.expectEqual(@as(types.MicroAion, 1), chain.state.get(sender).?.balance);
    try std.testing.expect(chain.state.get(receiver) == null);
}

test "genesis block has expected shape" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, 12345);
    defer chain.deinit();

    try std.testing.expectEqual(@as(u64, 0), chain.height());
    const genesis = chain.tip();
    try std.testing.expectEqual(@as(u64, 0), genesis.header.height);
    try std.testing.expectEqualSlices(u8, &types.ZERO_HASH, &genesis.header.previous_hash);
    try std.testing.expectEqual(@as(u64, 12345), genesis.header.timestamp);
    try std.testing.expectEqual(@as(usize, 0), genesis.transactions.len);
    try std.testing.expectEqual(@as(u8, 0), genesis.header.difficulty);
    try std.testing.expect(genesis.isHashValid());
}

test "block with wrong parent hash is rejected" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, 1);
    defer chain.deinit();

    const keys = try testKeyPair(0x41);
    const addr = @import("crypto.zig").addressFromPublicKey(keys.public_key);
    var validators = try validator_mod.ValidatorSet.init(allocator, &.{
        .{ .address = addr, .stake = 100 },
    });
    defer validators.deinit();

    var candidate = try block_mod.Block.init(allocator, 1, @splat(0xFF), 2, &.{}, 0);
    defer candidate.deinit(allocator);

    const proposal = try signProposal(1, 0, candidate.hash, addr, keys);
    const vote = try signVote(1, 0, candidate.hash, addr, keys);
    var certificate = try bft.QuorumCertificate.init(allocator, 1, 0, candidate.hash, &.{vote});
    defer certificate.deinit();

    try std.testing.expectError(error.InvalidParent, chain.appendFinalized(candidate, proposal, certificate, validators));
    try std.testing.expectEqual(@as(u64, 0), chain.height());
}

test "block with wrong height is rejected" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, 1);
    defer chain.deinit();

    const keys = try testKeyPair(0x42);
    const addr = @import("crypto.zig").addressFromPublicKey(keys.public_key);
    var validators = try validator_mod.ValidatorSet.init(allocator, &.{
        .{ .address = addr, .stake = 100 },
    });
    defer validators.deinit();

    var candidate = try block_mod.Block.init(allocator, 5, chain.tip().hash, 2, &.{}, 0);
    defer candidate.deinit(allocator);

    const proposal = try signProposal(5, 0, candidate.hash, addr, keys);
    const vote = try signVote(5, 0, candidate.hash, addr, keys);
    var certificate = try bft.QuorumCertificate.init(allocator, 5, 0, candidate.hash, &.{vote});
    defer certificate.deinit();

    try std.testing.expectError(error.InvalidHeight, chain.appendFinalized(candidate, proposal, certificate, validators));
    try std.testing.expectEqual(@as(u64, 0), chain.height());
}

test "non-zero difficulty is rejected under BFT" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, 1);
    defer chain.deinit();

    const keys = try testKeyPair(0x43);
    const addr = @import("crypto.zig").addressFromPublicKey(keys.public_key);
    var validators = try validator_mod.ValidatorSet.init(allocator, &.{
        .{ .address = addr, .stake = 100 },
    });
    defer validators.deinit();

    var candidate = try block_mod.Block.init(allocator, 1, chain.tip().hash, 2, &.{}, 1); // difficulty 1
    defer candidate.deinit(allocator);

    const proposal = try signProposal(1, 0, candidate.hash, addr, keys);
    const vote = try signVote(1, 0, candidate.hash, addr, keys);
    var certificate = try bft.QuorumCertificate.init(allocator, 1, 0, candidate.hash, &.{vote});
    defer certificate.deinit();

    try std.testing.expectError(error.InvalidBftDifficulty, chain.appendFinalized(candidate, proposal, certificate, validators));
}

test "chain recovers state after restart from durable storage" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const sender_keys = try testKeyPair(0xC1);
    const receiver_keys = try testKeyPair(0xC2);
    const sender = @import("crypto.zig").addressFromPublicKey(sender_keys.public_key);
    const receiver = @import("crypto.zig").addressFromPublicKey(receiver_keys.public_key);

    // First run: commit a BFT-finalized transfer and persist it.
    {
        var storage = try storage_mod.Storage.init(allocator, root);
        defer storage.deinit();

        var chain = try Chain.initWithStorage(allocator, &storage, 1);
        defer chain.deinit();

        var validators = try validator_mod.ValidatorSet.init(allocator, &.{
            .{ .address = sender, .stake = 100 },
        });
        defer validators.deinit();

        (try chain.state.getOrCreate(sender)).balance = 100;

        var tx = @import("transaction.zig").SettlementTx{
            .from = sender,
            .to = receiver,
            .amount = 35,
            .nonce = 0,
        };
        try tx.sign(sender_keys);

        var candidate = try block_mod.Block.init(allocator, 1, chain.tip().hash, 2, &.{tx}, 0);
        defer candidate.deinit(allocator);

        const proposal = try signProposal(1, 0, candidate.hash, sender, sender_keys);
        const vote = try signVote(1, 0, candidate.hash, sender, sender_keys);
        var certificate = try bft.QuorumCertificate.init(allocator, 1, 0, candidate.hash, &.{vote});
        defer certificate.deinit();

        try chain.appendFinalized(candidate, proposal, certificate, validators);
        try std.testing.expectEqual(@as(u64, 1), chain.height());
        try std.testing.expectEqual(@as(u128, 65), chain.state.get(sender).?.balance);
        try std.testing.expectEqual(@as(u128, 35), chain.state.get(receiver).?.balance);
    }

    // Second run: pure replay — only balances derived from persisted txs survive.
    {
        var storage = try storage_mod.Storage.init(allocator, root);
        defer storage.deinit();

        var chain = try Chain.initWithStorage(allocator, &storage, 1);
        defer chain.deinit();

        try std.testing.expectEqual(@as(u64, 1), chain.height());
        try std.testing.expectEqual(@as(u128, 35), chain.state.get(receiver).?.balance);
        if (chain.state.get(sender)) |acc| {
            try std.testing.expectEqual(@as(u128, 0), acc.balance);
            try std.testing.expectEqual(@as(u64, 1), acc.nonce);
        }
    }
}

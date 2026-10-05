//! Validator-node orchestration for transaction submission and BFT finality.

const std = @import("std");
const bft = @import("bft.zig");
const block_mod = @import("block.zig");
const chain_mod = @import("chain.zig");
const crypto = @import("crypto.zig");
const mempool_mod = @import("mempool.zig");
const metrics_mod = @import("metrics.zig");
const network = @import("network.zig");
const transaction = @import("transaction.zig");
const types = @import("types.zig");
const validator_mod = @import("validator.zig");

pub const MAX_BLOCK_TRANSACTIONS: usize = block_mod.MAX_TRANSACTIONS;
pub const MIN_BLOCK_TRANSACTIONS: usize = 100;

pub const ProposedBlock = struct {
    allocator: std.mem.Allocator,
    block: block_mod.Block,
    proposal: bft.Proposal,

    pub fn deinit(self: *ProposedBlock) void {
        self.block.deinit(self.allocator);
    }
};

pub const Node = struct {
    allocator: std.mem.Allocator,
    chain: chain_mod.Chain,
    mempool: mempool_mod.Mempool,
    validators: validator_mod.ValidatorSet,
    key_pair: crypto.KeyPair,
    address: types.Address,
    round: u64,
    metrics: metrics_mod.Metrics,
    mutex: std.atomic.Value(bool),
    active_block: ?block_mod.Block,
    active_proposal: ?bft.Proposal,
    vote_collector: ?bft.VoteCollector,
    pending_block: ?block_mod.Block,
    pending_proposal: ?bft.Proposal,

    pub fn init(
        allocator: std.mem.Allocator,
        timestamp: u64,
        key_pair: crypto.KeyPair,
        validators: validator_mod.ValidatorSet,
        mempool_capacity: usize,
    ) !Node {
        const address = crypto.addressFromPublicKey(key_pair.public_key);
        if (validators.find(address) == null) return error.NotValidator;

        var chain = try chain_mod.Chain.init(allocator, timestamp);
        errdefer chain.deinit();
        return .{
            .allocator = allocator,
            .chain = chain,
            .mempool = mempool_mod.Mempool.init(allocator, mempool_capacity),
            .validators = validators,
            .key_pair = key_pair,
            .address = address,
            .round = 0,
            .metrics = metrics_mod.Metrics.init(),
            .mutex = std.atomic.Value(bool).init(false),
            .active_block = null,
            .active_proposal = null,
            .vote_collector = null,
            .pending_block = null,
            .pending_proposal = null,
        };
    }

    pub fn deinit(self: *Node) void {
        if (self.vote_collector) |*collector| collector.deinit();
        if (self.active_block) |*block| block.deinit(self.allocator);
        if (self.pending_block) |*block| block.deinit(self.allocator);
        self.mempool.deinit();
        self.chain.deinit();
        self.validators.deinit();
    }

    pub fn submitTransaction(self: *Node, tx: transaction.SettlementTx) !types.Hash {
        self.lock();
        defer self.unlock();
        const result = self.mempool.add(&self.chain.state, tx) catch |err| {
            // A duplicate is normal during peer gossip and is not an admission
            // failure. Conflicting nonces and all other invalid transactions are.
            if (err != error.DuplicateTransaction) self.metrics.incTransactionsRejected();
            return err;
        };
        self.metrics.incTransactionsSubmitted();
        return result;
    }

    pub fn handleMessage(self: *Node, message: network.Message) !void {
        switch (message) {
            .transaction => |tx| {
                _ = try self.submitTransaction(tx);
            },
            .proposal => |proposal| try self.acceptProposal(proposal),
            .vote => |vote| {
                if (try self.collectVote(vote)) |certificate_value| {
                    var certificate = certificate_value;
                    certificate.deinit();
                }
            },
        }
    }

    pub fn acceptProposal(self: *Node, proposal: bft.Proposal) !void {
        self.lock();
        defer self.unlock();
        if (!proposal.verify(self.validators)) return error.InvalidProposal;
        self.pending_proposal = proposal;
    }

    pub fn acceptBlock(self: *Node, block: block_mod.Block) !void {
        self.lock();
        defer self.unlock();
        if (self.pending_block) |*existing| existing.deinit(self.allocator);
        self.pending_block = block;
    }

    /// Consume and commit a block accompanied by its proposal and quorum proof.
    /// A peer can therefore converge without trusting the proposing node.
    pub fn acceptFinalized(self: *Node, finalized: network.FinalizedBlock) !void {
        var owned = finalized;
        defer owned.deinit();

        self.lock();
        defer self.unlock();

        if (owned.block.header.height <= self.chain.height()) {
            if (owned.block.header.height == self.chain.height() and
                std.mem.eql(u8, &owned.block.hash, &self.chain.tip().hash)) return;
            return error.ConflictingFinalizedBlock;
        }
        try self.chain.appendFinalized(owned.block, owned.proposal, owned.certificate, self.validators);
        self.mempool.removeIncluded(owned.block.transactions);
        self.metrics.addTransactionsFinalized(owned.block.transactions.len);
        self.metrics.incBlocksFinalized();
        self.round = 0;
    }

    pub fn takePendingVote(self: *Node) !?bft.Vote {
        self.lock();
        defer self.unlock();
        const block = &(self.pending_block orelse return null);
        const proposal = self.pending_proposal orelse return null;
        const vote = try self.voteForProposalUnlocked(block.*, proposal);
        block.deinit(self.allocator);
        self.pending_block = null;
        self.pending_proposal = null;
        return vote;
    }

    fn voteForProposalUnlocked(self: *Node, candidate: block_mod.Block, proposal: bft.Proposal) !bft.Vote {
        if (!proposal.verify(self.validators)) return error.InvalidProposal;
        if (proposal.height != candidate.header.height) return error.InvalidProposal;
        if (!std.mem.eql(u8, &proposal.block_hash, &candidate.hash)) return error.InvalidProposal;
        if (candidate.header.height != self.chain.height() + 1) return error.InvalidHeight;
        if (!std.mem.eql(u8, &candidate.header.previous_hash, &self.chain.tip().hash)) return error.InvalidParent;
        if (!candidate.isHashValid()) return error.InvalidBlockHash;
        const expected_root = try block_mod.merkleRoot(self.allocator, candidate.transactions);
        if (!std.mem.eql(u8, &candidate.header.transaction_root, &expected_root)) return error.InvalidTransactionRoot;
        var simulated = try self.chain.state.clone();
        defer simulated.deinit();
        try simulated.applyTransactionsAtomic(candidate.transactions);
        var vote = bft.Vote{
            .height = proposal.height,
            .round = proposal.round,
            .block_hash = candidate.hash,
            .voter = self.address,
            .signature = undefined,
        };
        try vote.sign(self.key_pair);
        return vote;
    }

    pub fn voteForProposal(self: *Node, candidate: block_mod.Block, proposal: bft.Proposal) !bft.Vote {
        self.lock();
        defer self.unlock();

        if (!proposal.verify(self.validators)) return error.InvalidProposal;
        if (proposal.height != candidate.header.height) return error.InvalidProposal;
        if (!std.mem.eql(u8, &proposal.block_hash, &candidate.hash)) return error.InvalidProposal;
        if (candidate.header.height != self.chain.height() + 1) return error.InvalidHeight;
        if (!std.mem.eql(u8, &candidate.header.previous_hash, &self.chain.tip().hash)) return error.InvalidParent;
        if (!candidate.isHashValid()) return error.InvalidBlockHash;

        const expected_root = try block_mod.merkleRoot(self.allocator, candidate.transactions);
        if (!std.mem.eql(u8, &candidate.header.transaction_root, &expected_root)) {
            return error.InvalidTransactionRoot;
        }

        var simulated = try self.chain.state.clone();
        defer simulated.deinit();
        try simulated.applyTransactionsAtomic(candidate.transactions);

        var vote = bft.Vote{
            .height = proposal.height,
            .round = proposal.round,
            .block_hash = candidate.hash,
            .voter = self.address,
            .signature = undefined,
        };
        try vote.sign(self.key_pair);
        return vote;
    }

    pub fn beginVoteCollection(self: *Node, proposed: ProposedBlock) !void {
        self.lock();
        defer self.unlock();

        if (self.vote_collector) |*collector| collector.deinit();
        if (self.active_block) |*block| block.deinit(self.allocator);
        self.active_block = try proposed.block.clone(self.allocator);
        errdefer {
            if (self.active_block) |*block| block.deinit(self.allocator);
            self.active_block = null;
        }
        self.active_proposal = proposed.proposal;
        self.vote_collector = bft.VoteCollector.init(
            self.allocator,
            proposed.proposal.height,
            proposed.proposal.round,
            proposed.block.hash,
        );
    }

    pub fn collectVote(self: *Node, vote: bft.Vote) !?bft.QuorumCertificate {
        self.lock();
        defer self.unlock();

        var collector = &(self.vote_collector orelse return error.NoActiveProposal);
        self.metrics.incVotesReceived();
        if (!try collector.add(vote, self.validators)) return null;
        return try collector.certificate();
    }

    pub fn proposeBlock(self: *Node, timestamp: u64, max_transactions: usize) !ProposedBlock {
        self.lock();
        defer self.unlock();
        return self.proposeBlockUnlocked(timestamp, max_transactions);
    }

    fn proposeBlockUnlocked(self: *Node, timestamp: u64, max_transactions: usize) !ProposedBlock {
        const height = self.chain.height() + 1;
        const leader = self.validators.leader(height, self.round);
        if (!std.mem.eql(u8, &leader.address, &self.address)) return error.NotLeader;

        const transaction_limit = @min(max_transactions, MAX_BLOCK_TRANSACTIONS);
        const selected = try self.mempool.selectForBlock(self.allocator, &self.chain.state, transaction_limit);
        defer self.allocator.free(selected);
        var block = try block_mod.Block.init(
            self.allocator,
            height,
            self.chain.tip().hash,
            timestamp,
            selected,
            0,
        );
        errdefer block.deinit(self.allocator);

        var proposal = bft.Proposal{
            .height = height,
            .round = self.round,
            .block_hash = block.hash,
            .proposer = self.address,
            .signature = undefined,
        };
        try proposal.sign(self.key_pair);
        self.metrics.incBlocksProposed();
        return .{
            .allocator = self.allocator,
            .block = block,
            .proposal = proposal,
        };
    }

    pub fn finalizeBlock(self: *Node, proposed: *ProposedBlock, certificate: bft.QuorumCertificate) !void {
        self.lock();
        defer self.unlock();
        try self.finalizeBlockUnlocked(proposed, certificate);
    }

    fn finalizeBlockUnlocked(self: *Node, proposed: *ProposedBlock, certificate: bft.QuorumCertificate) !void {
        try self.chain.appendFinalized(proposed.block, proposed.proposal, certificate, self.validators);
        self.mempool.removeIncluded(proposed.block.transactions);
        self.metrics.addTransactionsFinalized(proposed.block.transactions.len);
        self.metrics.incBlocksFinalized();
        self.round = 0;
    }

    pub fn finalizePendingSingleValidator(self: *Node, timestamp: u64, max_transactions: usize) !bool {
        self.lock();
        defer self.unlock();
        return self.finalizePendingSingleValidatorUnlocked(timestamp, max_transactions);
    }

    fn finalizePendingSingleValidatorUnlocked(self: *Node, timestamp: u64, max_transactions: usize) !bool {
        if (self.validators.validators.len != 1) return error.SingleValidatorOnly;
        if (self.mempool.count() == 0) return false;

        const executable = try self.mempool.selectForBlock(self.allocator, &self.chain.state, max_transactions);
        defer self.allocator.free(executable);
        const minimum = @min(MIN_BLOCK_TRANSACTIONS, max_transactions);
        if (executable.len < minimum) return false;

        var proposed = try self.proposeBlockUnlocked(timestamp, max_transactions);
        defer proposed.deinit();

        var vote = bft.Vote{
            .height = proposed.proposal.height,
            .round = proposed.proposal.round,
            .block_hash = proposed.block.hash,
            .voter = self.address,
            .signature = undefined,
        };
        try vote.sign(self.key_pair);
        var certificate = try bft.QuorumCertificate.init(
            self.allocator,
            proposed.proposal.height,
            proposed.proposal.round,
            proposed.block.hash,
            &.{vote},
        );
        defer certificate.deinit();
        try self.finalizeBlockUnlocked(&proposed, certificate);
        return true;
    }

    pub fn pendingCount(self: *Node) usize {
        self.lock();
        defer self.unlock();
        return self.mempool.count();
    }

    fn lock(self: *Node) void {
        while (self.mutex.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Node) void {
        self.mutex.store(false, .release);
    }
};

test "node submits, proposes, and finalizes a BFT block" {
    const allocator = std.testing.allocator;
    const sender_keys = try crypto.KeyPair.generateDeterministic(@splat(0x61));
    const leader_keys = try crypto.KeyPair.generateDeterministic(@splat(0x62));
    const receiver_keys = try crypto.KeyPair.generateDeterministic(@splat(0x63));
    const sender = crypto.addressFromPublicKey(sender_keys.public_key);
    const leader = crypto.addressFromPublicKey(leader_keys.public_key);
    const receiver = crypto.addressFromPublicKey(receiver_keys.public_key);

    const validators = try validator_mod.ValidatorSet.init(allocator, &.{
        .{ .address = sender, .stake = 50 },
        .{ .address = leader, .stake = 30 },
    });
    var node = try Node.init(allocator, 1, leader_keys, validators, 16);
    defer node.deinit();
    (try node.chain.state.getOrCreate(sender)).balance = 100;

    var tx = transaction.SettlementTx{ .from = sender, .to = receiver, .amount = 25, .nonce = 0 };
    try tx.sign(sender_keys);
    _ = try node.submitTransaction(tx);

    var proposed = try node.proposeBlock(2, 100);
    defer proposed.deinit();
    try node.beginVoteCollection(proposed);

    var sender_vote = bft.Vote{
        .height = proposed.proposal.height,
        .round = proposed.proposal.round,
        .block_hash = proposed.block.hash,
        .voter = sender,
        .signature = undefined,
    };
    try sender_vote.sign(sender_keys);
    const leader_vote = try node.voteForProposal(proposed.block, proposed.proposal);
    try std.testing.expect((try node.collectVote(leader_vote)) == null);
    var certificate = (try node.collectVote(sender_vote)) orelse return error.QuorumNotReached;
    defer certificate.deinit();

    try node.finalizeBlock(&proposed, certificate);
    try std.testing.expectEqual(@as(u64, 1), node.chain.height());
    try std.testing.expectEqual(@as(u128, 75), node.chain.state.get(sender).?.balance);
    try std.testing.expectEqual(@as(u128, 25), node.chain.state.get(receiver).?.balance);
    try std.testing.expectEqual(@as(usize, 0), node.mempool.count());
}

test "a follower commits a certified finalized block from its leader" {
    const allocator = std.testing.allocator;
    const follower_keys = try crypto.KeyPair.generateDeterministic(@splat(0xC1));
    const leader_keys = try crypto.KeyPair.generateDeterministic(@splat(0xC2));
    const receiver_keys = try crypto.KeyPair.generateDeterministic(@splat(0xC3));
    const follower_address = crypto.addressFromPublicKey(follower_keys.public_key);
    const leader_address = crypto.addressFromPublicKey(leader_keys.public_key);
    const receiver = crypto.addressFromPublicKey(receiver_keys.public_key);

    const leader_validators = try validator_mod.ValidatorSet.init(allocator, &.{
        .{ .address = follower_address, .stake = 50 },
        .{ .address = leader_address, .stake = 50 },
    });
    var leader = try Node.init(allocator, 1, leader_keys, leader_validators, 16);
    defer leader.deinit();
    const follower_validators = try validator_mod.ValidatorSet.init(allocator, &.{
        .{ .address = follower_address, .stake = 50 },
        .{ .address = leader_address, .stake = 50 },
    });
    var follower = try Node.init(allocator, 1, follower_keys, follower_validators, 16);
    defer follower.deinit();
    (try leader.chain.state.getOrCreate(follower_address)).balance = 100;

    var tx = transaction.SettlementTx{ .from = follower_address, .to = receiver, .amount = 25, .nonce = 0 };
    try tx.sign(follower_keys);
    _ = try leader.submitTransaction(tx);
    var proposed = try leader.proposeBlock(2, 1);
    defer proposed.deinit();

    var follower_vote = bft.Vote{
        .height = proposed.proposal.height,
        .round = proposed.proposal.round,
        .block_hash = proposed.block.hash,
        .voter = follower_address,
        .signature = undefined,
    };
    try follower_vote.sign(follower_keys);
    const leader_vote = try leader.voteForProposal(proposed.block, proposed.proposal);
    var certificate = try bft.QuorumCertificate.init(
        allocator,
        proposed.proposal.height,
        proposed.proposal.round,
        proposed.block.hash,
        &.{ follower_vote, leader_vote },
    );
    defer certificate.deinit();

    const finalization = network.FinalizedBlock{
        .allocator = allocator,
        .block = try proposed.block.clone(allocator),
        .proposal = proposed.proposal,
        .certificate = try bft.QuorumCertificate.init(
            allocator,
            certificate.height,
            certificate.round,
            certificate.block_hash,
            certificate.votes,
        ),
    };
    try follower.acceptFinalized(finalization);

    try std.testing.expectEqual(@as(u64, 1), follower.chain.height());
    try std.testing.expectEqual(@as(types.MicroAion, 75), follower.chain.state.get(follower_address).?.balance);
    try std.testing.expectEqual(@as(types.MicroAion, 25), follower.chain.state.get(receiver).?.balance);
}

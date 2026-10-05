//! Signed BFT messages and quorum certificates.

const std = @import("std");
const crypto = @import("crypto.zig");
const types = @import("types.zig");
const validator_mod = @import("validator.zig");

pub const Proposal = struct {
    height: u64,
    round: u64,
    block_hash: types.Hash,
    proposer: types.Address,
    signature: crypto.Signature,

    pub fn sign(self: *Proposal, key_pair: crypto.KeyPair) !void {
        self.signature = try crypto.sign(key_pair, &self.signingBytes());
    }

    pub fn verify(self: Proposal, validators: validator_mod.ValidatorSet) bool {
        if (!std.mem.eql(u8, &validators.leader(self.height, self.round).address, &self.proposer)) return false;
        return crypto.verify(.{ .bytes = self.proposer }, &self.signingBytes(), self.signature);
    }

    fn signingBytes(self: Proposal) [48]u8 {
        var bytes: [48]u8 = undefined;
        @memcpy(bytes[0..32], &self.block_hash);
        std.mem.writeInt(u64, bytes[32..40], self.height, .little);
        std.mem.writeInt(u64, bytes[40..48], self.round, .little);
        return bytes;
    }
};

pub const Vote = struct {
    height: u64,
    round: u64,
    block_hash: types.Hash,
    voter: types.Address,
    signature: crypto.Signature,

    pub fn sign(self: *Vote, key_pair: crypto.KeyPair) !void {
        self.signature = try crypto.sign(key_pair, &self.signingBytes());
    }

    pub fn verify(self: Vote, validators: validator_mod.ValidatorSet) bool {
        if (validators.find(self.voter) == null) return false;
        return crypto.verify(.{ .bytes = self.voter }, &self.signingBytes(), self.signature);
    }

    fn signingBytes(self: Vote) [48]u8 {
        var bytes: [48]u8 = undefined;
        @memcpy(bytes[0..32], &self.block_hash);
        std.mem.writeInt(u64, bytes[32..40], self.height, .little);
        std.mem.writeInt(u64, bytes[40..48], self.round, .little);
        return bytes;
    }
};

pub const QuorumCertificate = struct {
    allocator: std.mem.Allocator,
    height: u64,
    round: u64,
    block_hash: types.Hash,
    votes: []const Vote,

    pub fn init(
        allocator: std.mem.Allocator,
        height: u64,
        round: u64,
        block_hash: types.Hash,
        votes: []const Vote,
    ) !QuorumCertificate {
        return .{
            .allocator = allocator,
            .height = height,
            .round = round,
            .block_hash = block_hash,
            .votes = try allocator.dupe(Vote, votes),
        };
    }

    pub fn deinit(self: *QuorumCertificate) void {
        self.allocator.free(self.votes);
    }

    pub fn verify(self: QuorumCertificate, validators: validator_mod.ValidatorSet) bool {
        var signed_stake: types.MicroAion = 0;
        for (self.votes, 0..) |vote, index| {
            if (vote.height != self.height or vote.round != self.round) return false;
            if (!std.mem.eql(u8, &vote.block_hash, &self.block_hash)) return false;
            if (!vote.verify(validators)) return false;

            const validator = validators.find(vote.voter) orelse return false;
            for (self.votes[0..index]) |previous| {
                if (std.mem.eql(u8, &previous.voter, &vote.voter)) return false;
            }
            signed_stake = std.math.add(types.MicroAion, signed_stake, validator.stake) catch return false;
        }
        return validators.hasQuorum(signed_stake);
    }
};

pub const VoteCollector = struct {
    allocator: std.mem.Allocator,
    height: u64,
    round: u64,
    block_hash: types.Hash,
    votes: std.ArrayList(Vote),

    pub fn init(
        allocator: std.mem.Allocator,
        height: u64,
        round: u64,
        block_hash: types.Hash,
    ) VoteCollector {
        return .{
            .allocator = allocator,
            .height = height,
            .round = round,
            .block_hash = block_hash,
            .votes = std.ArrayList(Vote).empty,
        };
    }

    pub fn deinit(self: *VoteCollector) void {
        self.votes.deinit(self.allocator);
    }

    pub fn add(self: *VoteCollector, vote: Vote, validators: validator_mod.ValidatorSet) !bool {
        if (vote.height != self.height or vote.round != self.round) return error.InvalidVoteContext;
        if (!std.mem.eql(u8, &vote.block_hash, &self.block_hash)) return error.InvalidVoteBlock;
        if (!vote.verify(validators)) return error.InvalidVoteSignature;
        for (self.votes.items) |existing| {
            if (std.mem.eql(u8, &existing.voter, &vote.voter)) return error.DuplicateVote;
        }

        try self.votes.append(self.allocator, vote);
        return self.hasQuorum(validators);
    }

    pub fn hasQuorum(self: VoteCollector, validators: validator_mod.ValidatorSet) bool {
        var stake: types.MicroAion = 0;
        for (self.votes.items) |vote| {
            const validator = validators.find(vote.voter) orelse continue;
            stake = std.math.add(types.MicroAion, stake, validator.stake) catch return false;
        }
        return validators.hasQuorum(stake);
    }

    pub fn certificate(self: VoteCollector) !QuorumCertificate {
        return QuorumCertificate.init(
            self.allocator,
            self.height,
            self.round,
            self.block_hash,
            self.votes.items,
        );
    }
};

test "signed votes form a stake-weighted quorum certificate" {
    const allocator = std.testing.allocator;
    const first = try crypto.KeyPair.generateDeterministic(@splat(1));
    const second = try crypto.KeyPair.generateDeterministic(@splat(2));
    const third = try crypto.KeyPair.generateDeterministic(@splat(3));
    const first_address = crypto.addressFromPublicKey(first.public_key);
    const second_address = crypto.addressFromPublicKey(second.public_key);
    const third_address = crypto.addressFromPublicKey(third.public_key);
    var validators = try validator_mod.ValidatorSet.init(allocator, &.{
        .{ .address = first_address, .stake = 50 },
        .{ .address = second_address, .stake = 30 },
        .{ .address = third_address, .stake = 20 },
    });
    defer validators.deinit();

    const block_hash: types.Hash = @splat(1);
    var first_vote = Vote{
        .height = 1,
        .round = 0,
        .block_hash = block_hash,
        .voter = first_address,
        .signature = undefined,
    };
    var second_vote = Vote{
        .height = 1,
        .round = 0,
        .block_hash = block_hash,
        .voter = second_address,
        .signature = undefined,
    };
    try first_vote.sign(first);
    try second_vote.sign(second);

    var certificate = try QuorumCertificate.init(allocator, 1, 0, block_hash, &.{ first_vote, second_vote });
    defer certificate.deinit();
    try std.testing.expect(certificate.verify(validators));
}

test "vote collector reaches quorum and rejects duplicates" {
    const allocator = std.testing.allocator;
    const first = try crypto.KeyPair.generateDeterministic(@splat(0xA1));
    const second = try crypto.KeyPair.generateDeterministic(@splat(0xA2));
    const first_address = crypto.addressFromPublicKey(first.public_key);
    const second_address = crypto.addressFromPublicKey(second.public_key);
    var validators = try validator_mod.ValidatorSet.init(allocator, &.{
        .{ .address = first_address, .stake = 50 },
        .{ .address = second_address, .stake = 50 },
    });
    defer validators.deinit();

    const block_hash: types.Hash = @splat(0xA3);
    var first_vote = Vote{
        .height = 2,
        .round = 0,
        .block_hash = block_hash,
        .voter = first_address,
        .signature = undefined,
    };
    var second_vote = Vote{
        .height = 2,
        .round = 0,
        .block_hash = block_hash,
        .voter = second_address,
        .signature = undefined,
    };
    try first_vote.sign(first);
    try second_vote.sign(second);

    var collector = VoteCollector.init(allocator, 2, 0, block_hash);
    defer collector.deinit();
    try std.testing.expect(!try collector.add(first_vote, validators));
    try std.testing.expectError(error.DuplicateVote, collector.add(first_vote, validators));
    try std.testing.expect(try collector.add(second_vote, validators));

    var certificate = try collector.certificate();
    defer certificate.deinit();
    try std.testing.expect(certificate.verify(validators));
}

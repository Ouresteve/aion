//! Versioned, fixed-layout binary encoding for peer messages.

const std = @import("std");
const bft = @import("bft.zig");
const block_mod = @import("block.zig");
const crypto = @import("crypto.zig");
const network = @import("network.zig");
const transaction = @import("transaction.zig");
const types = @import("types.zig");

pub const VERSION: u8 = 1;
const HEADER_SIZE: usize = 6;
const TRANSACTION_SIZE: usize = 152;
const CONSENSUS_SIZE: usize = 144;
const BLOCK_HEADER_SIZE: usize = 8 + 32 + 8 + 32 + 1 + 8 + 32 + 4;
const CERTIFICATE_HEADER_SIZE: usize = 8 + 8 + 32 + 4;

pub fn encode(allocator: std.mem.Allocator, message: network.Message) ![]u8 {
    const payload_size: usize = switch (message) {
        .transaction => TRANSACTION_SIZE,
        .proposal, .vote => CONSENSUS_SIZE,
    };
    const encoded = try allocator.alloc(u8, HEADER_SIZE + payload_size);
    encoded[0] = VERSION;
    encoded[1] = messageTag(message);
    std.mem.writeInt(u32, encoded[2..6], @intCast(payload_size), .little);

    switch (message) {
        .transaction => |tx| encodeTransaction(encoded[HEADER_SIZE..], tx),
        .proposal => |proposal| encodeProposal(encoded[HEADER_SIZE..], proposal),
        .vote => |vote| encodeVote(encoded[HEADER_SIZE..], vote),
    }
    return encoded;
}

pub fn decode(bytes: []const u8) !network.Message {
    if (bytes.len < HEADER_SIZE) return error.FrameTooShort;
    if (bytes[0] != VERSION) return error.UnsupportedVersion;
    const payload_size = std.mem.readInt(u32, bytes[2..6], .little);
    if (bytes.len != HEADER_SIZE + payload_size) return error.InvalidFrameLength;

    return switch (bytes[1]) {
        1 => if (payload_size == TRANSACTION_SIZE)
            .{ .transaction = decodeTransaction(bytes[HEADER_SIZE..]) }
        else
            error.InvalidPayloadLength,
        2 => if (payload_size == CONSENSUS_SIZE)
            .{ .proposal = decodeProposal(bytes[HEADER_SIZE..]) }
        else
            error.InvalidPayloadLength,
        3 => if (payload_size == CONSENSUS_SIZE)
            .{ .vote = decodeVote(bytes[HEADER_SIZE..]) }
        else
            error.InvalidPayloadLength,
        else => error.UnknownMessageType,
    };
}

pub fn encodeBlock(allocator: std.mem.Allocator, block: block_mod.Block) ![]u8 {
    const payload_size = try blockPayloadSize(block.transactions.len);
    const encoded = try allocator.alloc(u8, HEADER_SIZE + payload_size);
    encoded[0] = VERSION;
    encoded[1] = 4;
    std.mem.writeInt(u32, encoded[2..6], @intCast(payload_size), .little);
    encodeBlockPayload(encoded[HEADER_SIZE..], block);
    return encoded;
}

pub fn encodeFinalizedBlock(
    allocator: std.mem.Allocator,
    block: block_mod.Block,
    proposal: bft.Proposal,
    certificate: bft.QuorumCertificate,
) ![]u8 {
    const block_payload_size = try blockPayloadSize(block.transactions.len);
    if (certificate.votes.len > block_mod.MAX_TRANSACTIONS) return error.CertificateTooLarge;
    const payload_size = block_payload_size + CONSENSUS_SIZE + CERTIFICATE_HEADER_SIZE + certificate.votes.len * CONSENSUS_SIZE;
    const encoded = try allocator.alloc(u8, HEADER_SIZE + payload_size);
    encoded[0] = VERSION;
    encoded[1] = 5;
    std.mem.writeInt(u32, encoded[2..6], @intCast(payload_size), .little);

    encodeBlockPayload(encoded[HEADER_SIZE..][0..block_payload_size], block);
    var output = encoded[HEADER_SIZE + block_payload_size ..];
    encodeProposal(output[0..CONSENSUS_SIZE], proposal);
    output = output[CONSENSUS_SIZE..];
    std.mem.writeInt(u64, output[0..8], certificate.height, .little);
    std.mem.writeInt(u64, output[8..16], certificate.round, .little);
    @memcpy(output[16..48], &certificate.block_hash);
    std.mem.writeInt(u32, output[48..52], @intCast(certificate.votes.len), .little);
    output = output[CERTIFICATE_HEADER_SIZE..];
    for (certificate.votes) |vote| {
        encodeVote(output[0..CONSENSUS_SIZE], vote);
        output = output[CONSENSUS_SIZE..];
    }
    return encoded;
}

pub fn decodeFinalizedBlock(allocator: std.mem.Allocator, bytes: []const u8) !network.FinalizedBlock {
    if (bytes.len < HEADER_SIZE + BLOCK_HEADER_SIZE + CONSENSUS_SIZE + CERTIFICATE_HEADER_SIZE) {
        return error.FrameTooShort;
    }
    if (bytes[0] != VERSION or bytes[1] != 5) return error.InvalidFinalizedBlockFrame;
    const payload_size = std.mem.readInt(u32, bytes[2..6], .little);
    if (bytes.len != HEADER_SIZE + payload_size) return error.InvalidFrameLength;

    const payload = bytes[HEADER_SIZE..];
    const transaction_count = std.mem.readInt(u32, payload[121..125], .little);
    if (transaction_count > block_mod.MAX_TRANSACTIONS) return error.BlockTooLarge;
    const block_payload_size = try blockPayloadSize(transaction_count);
    if (payload.len < block_payload_size + CONSENSUS_SIZE + CERTIFICATE_HEADER_SIZE) return error.InvalidPayloadLength;

    const certificate_input = payload[block_payload_size + CONSENSUS_SIZE ..];
    const vote_count = std.mem.readInt(u32, certificate_input[48..52], .little);
    if (vote_count > block_mod.MAX_TRANSACTIONS) return error.CertificateTooLarge;
    const expected_size = block_payload_size + CONSENSUS_SIZE + CERTIFICATE_HEADER_SIZE + @as(usize, vote_count) * CONSENSUS_SIZE;
    if (payload_size != expected_size) return error.InvalidPayloadLength;

    var block = try decodeBlockPayload(allocator, payload[0..block_payload_size]);
    errdefer block.deinit(allocator);
    const proposal = decodeProposal(payload[block_payload_size..][0..CONSENSUS_SIZE]);
    const votes = try allocator.alloc(bft.Vote, vote_count);
    defer allocator.free(votes);
    var vote_input = certificate_input[CERTIFICATE_HEADER_SIZE..];
    for (votes) |*vote| {
        vote.* = decodeVote(vote_input[0..CONSENSUS_SIZE]);
        vote_input = vote_input[CONSENSUS_SIZE..];
    }
    const certificate = try bft.QuorumCertificate.init(
        allocator,
        std.mem.readInt(u64, certificate_input[0..8], .little),
        std.mem.readInt(u64, certificate_input[8..16], .little),
        certificate_input[16..48].*,
        votes,
    );
    return .{
        .allocator = allocator,
        .block = block,
        .proposal = proposal,
        .certificate = certificate,
    };
}

fn encodeBlockPayload(output: []u8, block: block_mod.Block) void {
    std.mem.writeInt(u64, output[0..8], block.header.height, .little);
    @memcpy(output[8..40], &block.header.previous_hash);
    std.mem.writeInt(u64, output[40..48], block.header.timestamp, .little);
    @memcpy(output[48..80], &block.header.transaction_root);
    output[80] = block.header.difficulty;
    std.mem.writeInt(u64, output[81..89], block.header.nonce, .little);
    @memcpy(output[89..121], &block.hash);
    std.mem.writeInt(u32, output[121..125], @intCast(block.transactions.len), .little);
    var transaction_output = output[BLOCK_HEADER_SIZE..];
    for (block.transactions) |tx| {
        encodeTransaction(transaction_output[0..TRANSACTION_SIZE], tx);
        transaction_output = transaction_output[TRANSACTION_SIZE..];
    }
}

fn blockPayloadSize(transaction_count: anytype) !usize {
    if (transaction_count > block_mod.MAX_TRANSACTIONS) return error.BlockTooLarge;
    return BLOCK_HEADER_SIZE + @as(usize, @intCast(transaction_count)) * TRANSACTION_SIZE;
}

pub fn decodeBlock(allocator: std.mem.Allocator, bytes: []const u8) !block_mod.Block {
    if (bytes.len < HEADER_SIZE + BLOCK_HEADER_SIZE) return error.FrameTooShort;
    if (bytes[0] != VERSION or bytes[1] != 4) return error.InvalidBlockFrame;
    const payload_size = std.mem.readInt(u32, bytes[2..6], .little);
    if (bytes.len != HEADER_SIZE + payload_size) return error.InvalidFrameLength;

    return decodeBlockPayload(allocator, bytes[HEADER_SIZE..]);
}

fn decodeBlockPayload(allocator: std.mem.Allocator, input: []const u8) !block_mod.Block {
    if (input.len < BLOCK_HEADER_SIZE) return error.FrameTooShort;
    const transaction_count = std.mem.readInt(u32, input[121..125], .little);
    if (transaction_count > block_mod.MAX_TRANSACTIONS) return error.BlockTooLarge;
    if (input.len != try blockPayloadSize(transaction_count)) return error.InvalidPayloadLength;

    const transactions = try allocator.alloc(transaction.SettlementTx, transaction_count);
    errdefer allocator.free(transactions);
    var tx_input = input[BLOCK_HEADER_SIZE..];
    for (transactions) |*tx| {
        tx.* = decodeTransaction(tx_input[0..TRANSACTION_SIZE]);
        tx_input = tx_input[TRANSACTION_SIZE..];
    }

    var block = try block_mod.Block.init(
        allocator,
        std.mem.readInt(u64, input[0..8], .little),
        input[8..40].*,
        std.mem.readInt(u64, input[40..48], .little),
        transactions,
        input[80],
    );
    allocator.free(transactions);
    block.header.nonce = std.mem.readInt(u64, input[81..89], .little);
    block.hash = input[89..121].*;
    if (!block.isHashValid()) {
        block.deinit(allocator);
        return error.InvalidBlockHash;
    }
    return block;
}

fn messageTag(message: network.Message) u8 {
    return switch (message) {
        .transaction => 1,
        .proposal => 2,
        .vote => 3,
    };
}

fn encodeTransaction(output: []u8, tx: transaction.SettlementTx) void {
    @memcpy(output[0..32], &tx.from);
    @memcpy(output[32..64], &tx.to);
    std.mem.writeInt(u128, output[64..80], tx.amount, .little);
    std.mem.writeInt(u64, output[80..88], tx.nonce, .little);
    const signature_bytes = crypto.signatureBytes(tx.signature);
    @memcpy(output[88..152], &signature_bytes);
}

fn decodeTransaction(input: []const u8) transaction.SettlementTx {
    var signature_bytes: [crypto.Signature.encoded_length]u8 = undefined;
    @memcpy(&signature_bytes, input[88..152]);
    return .{
        .from = input[0..32].*,
        .to = input[32..64].*,
        .amount = std.mem.readInt(u128, input[64..80], .little),
        .nonce = std.mem.readInt(u64, input[80..88], .little),
        .signature = crypto.signatureFromBytes(signature_bytes),
    };
}

fn encodeProposal(output: []u8, proposal: bft.Proposal) void {
    @memcpy(output[0..32], &proposal.block_hash);
    std.mem.writeInt(u64, output[32..40], proposal.height, .little);
    std.mem.writeInt(u64, output[40..48], proposal.round, .little);
    @memcpy(output[48..80], &proposal.proposer);
    const signature_bytes = crypto.signatureBytes(proposal.signature);
    @memcpy(output[80..144], &signature_bytes);
}

fn decodeProposal(input: []const u8) bft.Proposal {
    var signature_bytes: [crypto.Signature.encoded_length]u8 = undefined;
    @memcpy(&signature_bytes, input[80..144]);
    return .{
        .block_hash = input[0..32].*,
        .height = std.mem.readInt(u64, input[32..40], .little),
        .round = std.mem.readInt(u64, input[40..48], .little),
        .proposer = input[48..80].*,
        .signature = crypto.signatureFromBytes(signature_bytes),
    };
}

fn encodeVote(output: []u8, vote: bft.Vote) void {
    @memcpy(output[0..32], &vote.block_hash);
    std.mem.writeInt(u64, output[32..40], vote.height, .little);
    std.mem.writeInt(u64, output[40..48], vote.round, .little);
    @memcpy(output[48..80], &vote.voter);
    const signature_bytes = crypto.signatureBytes(vote.signature);
    @memcpy(output[80..144], &signature_bytes);
}

fn decodeVote(input: []const u8) bft.Vote {
    var signature_bytes: [crypto.Signature.encoded_length]u8 = undefined;
    @memcpy(&signature_bytes, input[80..144]);
    return .{
        .block_hash = input[0..32].*,
        .height = std.mem.readInt(u64, input[32..40], .little),
        .round = std.mem.readInt(u64, input[40..48], .little),
        .voter = input[48..80].*,
        .signature = crypto.signatureFromBytes(signature_bytes),
    };
}

test "codec round trips signed transaction and rejects malformed frames" {
    const allocator = std.testing.allocator;
    const keys = try crypto.KeyPair.generateDeterministic(@splat(0x81));
    const from = crypto.addressFromPublicKey(keys.public_key);
    var tx = transaction.SettlementTx{
        .from = from,
        .to = @splat(2),
        .amount = 100,
        .nonce = 4,
    };
    try tx.sign(keys);

    const encoded = try encode(allocator, .{ .transaction = tx });
    defer allocator.free(encoded);
    const decoded = try decode(encoded);
    try std.testing.expectEqual(tx.hash(), decoded.transaction.hash());
    try std.testing.expect(decoded.transaction.verify());

    try std.testing.expectError(error.UnsupportedVersion, decode(&[_]u8{ 2, 1, 0, 0, 0, 0 }));
    try std.testing.expectError(error.FrameTooShort, decode(&[_]u8{1}));
}

test "codec round trips a block frame" {
    const allocator = std.testing.allocator;
    var block = try block_mod.Block.init(allocator, 3, @splat(1), 9, &.{}, 0);
    defer block.deinit(allocator);
    const encoded = try encodeBlock(allocator, block);
    defer allocator.free(encoded);
    var decoded = try decodeBlock(allocator, encoded);
    defer decoded.deinit(allocator);
    try std.testing.expectEqual(block.hash, decoded.hash);
    try std.testing.expectEqual(block.header.height, decoded.header.height);
}

test "codec round trips a certified finalized block frame" {
    const allocator = std.testing.allocator;
    const first = try crypto.KeyPair.generateDeterministic(@splat(0xD1));
    const second = try crypto.KeyPair.generateDeterministic(@splat(0xD2));
    const first_address = crypto.addressFromPublicKey(first.public_key);
    const second_address = crypto.addressFromPublicKey(second.public_key);
    var block = try block_mod.Block.init(allocator, 1, @splat(0xD3), 9, &.{}, 0);
    defer block.deinit(allocator);
    var proposal = bft.Proposal{
        .height = 1,
        .round = 0,
        .block_hash = block.hash,
        .proposer = first_address,
        .signature = undefined,
    };
    try proposal.sign(first);
    var first_vote = bft.Vote{ .height = 1, .round = 0, .block_hash = block.hash, .voter = first_address, .signature = undefined };
    var second_vote = bft.Vote{ .height = 1, .round = 0, .block_hash = block.hash, .voter = second_address, .signature = undefined };
    try first_vote.sign(first);
    try second_vote.sign(second);
    var certificate = try bft.QuorumCertificate.init(allocator, 1, 0, block.hash, &.{ first_vote, second_vote });
    defer certificate.deinit();

    const encoded = try encodeFinalizedBlock(allocator, block, proposal, certificate);
    defer allocator.free(encoded);
    var decoded = try decodeFinalizedBlock(allocator, encoded);
    defer decoded.deinit();
    try std.testing.expectEqual(block.hash, decoded.block.hash);
    try std.testing.expectEqual(proposal.proposer, decoded.proposal.proposer);
    try std.testing.expectEqual(@as(usize, 2), decoded.certificate.votes.len);
}

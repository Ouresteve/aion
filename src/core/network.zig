//! Deterministic peer transport used before binding the protocol to sockets.

const std = @import("std");
const bft = @import("bft.zig");
const block_mod = @import("block.zig");
const crypto = @import("crypto.zig");
const transaction = @import("transaction.zig");
const types = @import("types.zig");

pub const Message = union(enum) {
    transaction: transaction.SettlementTx,
    proposal: bft.Proposal,
    vote: bft.Vote,
};

/// An owned, fully-certified block received from a peer. Unlike a proposal,
/// this carries the proof required to advance canonical state immediately.
pub const FinalizedBlock = struct {
    allocator: std.mem.Allocator,
    block: block_mod.Block,
    proposal: bft.Proposal,
    certificate: bft.QuorumCertificate,

    pub fn deinit(self: *FinalizedBlock) void {
        self.certificate.deinit();
        self.block.deinit(self.allocator);
    }
};

pub const Envelope = struct {
    from: types.Address,
    to: types.Address,
    message: Message,
};

const Link = struct {
    from: types.Address,
    to: types.Address,
};

pub const Network = struct {
    allocator: std.mem.Allocator,
    peers: std.AutoHashMap(types.Address, void),
    links: std.AutoHashMap(Link, void),
    queue: std.ArrayList(Envelope),

    pub fn init(allocator: std.mem.Allocator) Network {
        return .{
            .allocator = allocator,
            .peers = std.AutoHashMap(types.Address, void).init(allocator),
            .links = std.AutoHashMap(Link, void).init(allocator),
            .queue = std.ArrayList(Envelope).empty,
        };
    }

    pub fn deinit(self: *Network) void {
        self.queue.deinit(self.allocator);
        self.links.deinit();
        self.peers.deinit();
    }

    pub fn register(self: *Network, address: types.Address) !void {
        try self.peers.put(address, {});
    }

    pub fn connect(self: *Network, first: types.Address, second: types.Address) !void {
        if (!self.peers.contains(first) or !self.peers.contains(second)) return error.UnknownPeer;
        try self.links.put(.{ .from = first, .to = second }, {});
        try self.links.put(.{ .from = second, .to = first }, {});
    }

    pub fn send(self: *Network, from: types.Address, to: types.Address, message: Message) !void {
        if (!self.peers.contains(from) or !self.peers.contains(to)) return error.UnknownPeer;
        if (!self.links.contains(.{ .from = from, .to = to })) return error.NotConnected;
        try self.queue.append(self.allocator, .{ .from = from, .to = to, .message = message });
    }

    pub fn broadcast(self: *Network, from: types.Address, message: Message) !void {
        if (!self.peers.contains(from)) return error.UnknownPeer;
        var iterator = self.peers.iterator();
        while (iterator.next()) |entry| {
            const to = entry.key_ptr.*;
            if (!std.mem.eql(u8, &from, &to) and self.links.contains(.{ .from = from, .to = to })) {
                try self.queue.append(self.allocator, .{ .from = from, .to = to, .message = message });
            }
        }
    }

    pub fn receive(self: *Network, recipient: types.Address) ![]Envelope {
        var received = std.ArrayList(Envelope).empty;
        errdefer received.deinit(self.allocator);

        var write_index: usize = 0;
        for (self.queue.items) |envelope| {
            if (std.mem.eql(u8, &envelope.to, &recipient)) {
                try received.append(self.allocator, envelope);
            } else {
                self.queue.items[write_index] = envelope;
                write_index += 1;
            }
        }
        self.queue.shrinkRetainingCapacity(write_index);
        return try received.toOwnedSlice(self.allocator);
    }
};

test "network delivers only messages across connected peers" {
    const allocator = std.testing.allocator;
    const first_keys = try crypto.KeyPair.generateDeterministic(@splat(0x71));
    const second_keys = try crypto.KeyPair.generateDeterministic(@splat(0x72));
    const third_keys = try crypto.KeyPair.generateDeterministic(@splat(0x73));
    const first = crypto.addressFromPublicKey(first_keys.public_key);
    const second = crypto.addressFromPublicKey(second_keys.public_key);
    const third = crypto.addressFromPublicKey(third_keys.public_key);

    var network = Network.init(allocator);
    defer network.deinit();
    try network.register(first);
    try network.register(second);
    try network.register(third);
    try network.connect(first, second);

    const tx = transaction.SettlementTx{
        .from = first,
        .to = second,
        .amount = 1,
        .nonce = 0,
        .signature = undefined,
    };
    try network.send(first, second, .{ .transaction = tx });
    try std.testing.expectError(error.NotConnected, network.send(first, third, .{ .transaction = tx }));

    const received = try network.receive(second);
    defer allocator.free(received);
    try std.testing.expectEqual(@as(usize, 1), received.len);
    const third_received = try network.receive(third);
    defer allocator.free(third_received);
    try std.testing.expectEqual(@as(usize, 0), third_received.len);
}

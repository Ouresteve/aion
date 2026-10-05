//! TCP transport for versioned Aion peer frames.

const std = @import("std");
const codec = @import("codec.zig");
const block_mod = @import("block.zig");
const network = @import("network.zig");

const net = std.Io.net;
const FRAME_HEADER_SIZE: usize = 6;
const MAX_FRAME_SIZE: usize = 1024 * 1024;

pub const Frame = union(enum) {
    message: network.Message,
    block: block_mod.Block,
    finalized: network.FinalizedBlock,
};

pub const Listener = struct {
    io: std.Io,
    server: net.Server,

    pub fn init(io: std.Io, host: []const u8, port: u16) !Listener {
        var address = try net.IpAddress.parse(host, port);
        return .{
            .io = io,
            .server = try address.listen(io, .{ .reuse_address = true }),
        };
    }

    pub fn accept(self: *Listener) !net.Stream {
        return self.server.accept(self.io);
    }

    pub fn deinit(self: *Listener) void {
        self.server.deinit(self.io);
    }
};

pub fn connect(io: std.Io, host: []const u8, port: u16) !net.Stream {
    const address = try net.IpAddress.parse(host, port);
    return address.connect(io, .{ .mode = .stream, .protocol = .tcp });
}

pub fn send(io: std.Io, stream: net.Stream, allocator: std.mem.Allocator, message: network.Message) !void {
    const frame = try codec.encode(allocator, message);
    defer allocator.free(frame);
    try writeFrame(io, stream, frame);
}

pub fn sendBlock(io: std.Io, stream: net.Stream, allocator: std.mem.Allocator, block: block_mod.Block) !void {
    const frame = try codec.encodeBlock(allocator, block);
    defer allocator.free(frame);
    try writeFrame(io, stream, frame);
}

pub fn sendFinalized(
    io: std.Io,
    stream: net.Stream,
    allocator: std.mem.Allocator,
    block: block_mod.Block,
    proposal: @import("bft.zig").Proposal,
    certificate: @import("bft.zig").QuorumCertificate,
) !void {
    const frame = try codec.encodeFinalizedBlock(allocator, block, proposal, certificate);
    defer allocator.free(frame);
    try writeFrame(io, stream, frame);
}

fn writeFrame(io: std.Io, stream: net.Stream, frame: []const u8) !void {
    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll(frame);
    try writer.interface.flush();
}

pub fn receive(io: std.Io, stream: net.Stream, allocator: std.mem.Allocator) !network.Message {
    var read_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    return receiveFromReader(&reader, allocator);
}

pub fn receiveFromReader(reader: *std.Io.Reader, allocator: std.mem.Allocator) !network.Message {
    const frame = try receiveFrameFromReader(reader, allocator);
    return switch (frame) {
        .message => |message| message,
        .block => |block| {
            var owned = block;
            owned.deinit(allocator);
            return error.UnexpectedBlockFrame;
        },
        .finalized => |finalized| {
            var owned = finalized;
            owned.deinit();
            return error.UnexpectedFinalizedBlockFrame;
        },
    };
}

pub fn receiveFrameFromReader(reader: *std.Io.Reader, allocator: std.mem.Allocator) !Frame {
    const frame = try readFrame(reader, allocator);
    defer allocator.free(frame);
    return switch (frame[1]) {
        4 => .{ .block = try codec.decodeBlock(allocator, frame) },
        5 => .{ .finalized = try codec.decodeFinalizedBlock(allocator, frame) },
        else => .{ .message = try codec.decode(frame) },
    };
}

pub fn receiveBlockFromReader(reader: *std.Io.Reader, allocator: std.mem.Allocator) !block_mod.Block {
    const frame = try readFrame(reader, allocator);
    defer allocator.free(frame);
    return codec.decodeBlock(allocator, frame);
}

fn readFrame(reader: *std.Io.Reader, allocator: std.mem.Allocator) ![]u8 {
    var header: [FRAME_HEADER_SIZE]u8 = undefined;
    try reader.readSliceAll(&header);

    const payload_size = std.mem.readInt(u32, header[2..6], .little);
    const frame_size = FRAME_HEADER_SIZE + @as(usize, payload_size);
    if (frame_size > MAX_FRAME_SIZE) return error.FrameTooLarge;

    const frame = try allocator.alloc(u8, frame_size);
    @memcpy(frame[0..FRAME_HEADER_SIZE], &header);
    try reader.readSliceAll(frame[FRAME_HEADER_SIZE..]);
    return frame;
}

test "tcp frame size limit is bounded" {
    try std.testing.expect(MAX_FRAME_SIZE > FRAME_HEADER_SIZE);
}

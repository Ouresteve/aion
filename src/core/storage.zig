//! Persistent block storage (replay-only strategy).
//!
//! On-disk layout (ADR-0004):
//!
//!   data/
//!     blocks/
//!       00000000000000000000.bin
//!       ...
//!
//! Uses Zig 0.17 std.Io.Dir APIs.

const std = @import("std");
const block_mod = @import("block.zig");
const codec = @import("codec.zig");

pub const Storage = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root_path: []const u8,
    blocks_path: []u8,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, root_path: []const u8) !Storage {
        const blocks_path = try std.fs.path.join(allocator, &.{ root_path, "blocks" });
        errdefer allocator.free(blocks_path);

        var cwd = std.Io.Dir.cwd();
        try cwd.makePath(io, blocks_path);

        return .{
            .allocator = allocator,
            .io = io,
            .root_path = root_path,
            .blocks_path = blocks_path,
        };
    }

    pub fn deinit(self: *Storage) void {
        self.allocator.free(self.blocks_path);
    }

    pub fn saveBlock(self: *Storage, block: block_mod.Block) !void {
        const encoded = try codec.encodeBlock(self.allocator, block);
        defer self.allocator.free(encoded);

        var filename_buf: [32]u8 = undefined;
        const filename = try std.fmt.bufPrint(&filename_buf, "{d:0>20}.bin", .{block.header.height});

        const file_path = try std.fs.path.join(self.allocator, &.{ self.blocks_path, filename });
        defer self.allocator.free(file_path);

        var cwd = std.Io.Dir.cwd();
        const file = try cwd.createFile(self.io, file_path, .{});
        defer file.close(self.io);

        var write_buf: [4096]u8 = undefined;
        var writer = file.writerStreaming(self.io, &write_buf);
        try writer.interface.writeAll(encoded);
        try writer.interface.flush();
    }

    pub fn loadAllBlocks(self: *Storage) ![]block_mod.Block {
        var cwd = std.Io.Dir.cwd();
        var dir = try cwd.openDir(self.io, self.blocks_path, .{ .iterate = true });
        defer dir.close(self.io);

        var names = std.ArrayList([]u8).empty;
        defer {
            for (names.items) |name| self.allocator.free(name);
            names.deinit(self.allocator);
        }

        var it = dir.iterate(self.io);
        while (try it.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".bin")) continue;
            const owned = try self.allocator.dupe(u8, entry.name);
            errdefer self.allocator.free(owned);
            try names.append(self.allocator, owned);
        }

        std.mem.sort([]u8, names.items, {}, struct {
            fn less(_: void, a: []u8, b: []u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.less);

        var blocks = try self.allocator.alloc(block_mod.Block, names.items.len);
        errdefer {
            for (blocks[0..]) |*b| b.deinit(self.allocator);
            self.allocator.free(blocks);
        }

        for (names.items, 0..) |name, index| {
            const file_path = try std.fs.path.join(self.allocator, &.{ self.blocks_path, name });
            defer self.allocator.free(file_path);

            const content = try cwd.readFileAlloc(self.io, self.allocator, file_path, 16 * 1024 * 1024);
            defer self.allocator.free(content);

            blocks[index] = try codec.decodeBlock(self.allocator, content);
        }

        return blocks;
    }

    pub fn latestHeight(self: *Storage) !?u64 {
        const blocks = try self.loadAllBlocks();
        defer {
            for (blocks) |*b| b.deinit(self.allocator);
            self.allocator.free(blocks);
        }
        if (blocks.len == 0) return null;
        return blocks[blocks.len - 1].header.height;
    }
};

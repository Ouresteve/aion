//! Persistent block storage (replay-only strategy).
//!
//! On-disk layout (ADR-0004):
//!
//!   data/
//!     blocks/
//!       00000000000000000000.bin   # height 0
//!       00000000000000000001.bin
//!       ...
//!
//! Each file contains one length-prefixed block frame produced by codec.encodeBlock.
//! State is never stored; it is always rebuilt by replaying the chain.

const std = @import("std");
const block_mod = @import("block.zig");
const codec = @import("codec.zig");

pub const Storage = struct {
    allocator: std.mem.Allocator,
    root_path: []const u8,
    blocks_path: []u8,

    /// Create a Storage rooted at `root_path` (e.g. "data").
    /// The directory structure is created if it does not exist.
    pub fn init(allocator: std.mem.Allocator, root_path: []const u8) !Storage {
        const blocks_path = try std.fs.path.join(allocator, &.{ root_path, "blocks" });
        errdefer allocator.free(blocks_path);

        try std.fs.cwd().makePath(blocks_path);

        return .{
            .allocator = allocator,
            .root_path = root_path,
            .blocks_path = blocks_path,
        };
    }

    pub fn deinit(self: *Storage) void {
        self.allocator.free(self.blocks_path);
    }

    /// Persist a single finalized block. Overwrites any existing file at that height.
    pub fn saveBlock(self: *Storage, block: block_mod.Block) !void {
        const encoded = try codec.encodeBlock(self.allocator, block);
        defer self.allocator.free(encoded);

        var filename_buf: [32]u8 = undefined;
        const filename = try std.fmt.bufPrint(&filename_buf, "{d:0>20}.bin", .{block.header.height});

        const file_path = try std.fs.path.join(self.allocator, &.{ self.blocks_path, filename });
        defer self.allocator.free(file_path);

        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        try file.writeAll(encoded);
    }

    /// Load every block from disk in ascending height order.
    /// Caller owns the returned slice and must call `deinit` on each block then free the slice.
    pub fn loadAllBlocks(self: *Storage) ![]block_mod.Block {
        var dir = try std.fs.cwd().openDir(self.blocks_path, .{ .iterate = true });
        defer dir.close();

        var names = std.ArrayList([]u8).empty;
        defer {
            for (names.items) |name| self.allocator.free(name);
            names.deinit(self.allocator);
        }

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".bin")) continue;
            const owned = try self.allocator.dupe(u8, entry.name);
            errdefer self.allocator.free(owned);
            try names.append(self.allocator, owned);
        }

        // Sort lexicographically — zero-padded heights make this height order.
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

            const content = try std.fs.cwd().readFileAlloc(self.allocator, file_path, 16 * 1024 * 1024);
            defer self.allocator.free(content);

            blocks[index] = try codec.decodeBlock(self.allocator, content);
        }

        return blocks;
    }

    /// Highest height present on disk, or null if the store is empty.
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

test "storage round-trips a block" {
    const allocator = std.testing.allocator;

    // Use a unique temporary directory for the test.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    var storage = try Storage.init(allocator, root);
    defer storage.deinit();

    var block = try block_mod.Block.init(allocator, 0, @splat(0), 1, &.{}, 0);
    defer block.deinit(allocator);

    try storage.saveBlock(block);

    const loaded = try storage.loadAllBlocks();
    defer {
        for (loaded) |*b| b.deinit(allocator);
        allocator.free(loaded);
    }

    try std.testing.expectEqual(@as(usize, 1), loaded.len);
    try std.testing.expectEqual(block.header.height, loaded[0].header.height);
    try std.testing.expectEqual(block.hash, loaded[0].hash);
}

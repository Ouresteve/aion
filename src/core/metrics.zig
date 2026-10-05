//! Low-overhead node metrics with Prometheus text exposition.

const std = @import("std");

pub const Metrics = struct {
    transactions_submitted: std.atomic.Value(u64),
    transactions_rejected: std.atomic.Value(u64),
    transactions_finalized: std.atomic.Value(u64),
    blocks_proposed: std.atomic.Value(u64),
    blocks_finalized: std.atomic.Value(u64),
    consensus_votes_received: std.atomic.Value(u64),
    peer_messages_sent: std.atomic.Value(u64),
    peer_messages_received: std.atomic.Value(u64),
    bytes_sent: std.atomic.Value(u64),
    bytes_received: std.atomic.Value(u64),

    pub fn init() Metrics {
        return .{
            .transactions_submitted = std.atomic.Value(u64).init(0),
            .transactions_rejected = std.atomic.Value(u64).init(0),
            .transactions_finalized = std.atomic.Value(u64).init(0),
            .blocks_proposed = std.atomic.Value(u64).init(0),
            .blocks_finalized = std.atomic.Value(u64).init(0),
            .consensus_votes_received = std.atomic.Value(u64).init(0),
            .peer_messages_sent = std.atomic.Value(u64).init(0),
            .peer_messages_received = std.atomic.Value(u64).init(0),
            .bytes_sent = std.atomic.Value(u64).init(0),
            .bytes_received = std.atomic.Value(u64).init(0),
        };
    }

    pub fn incTransactionsSubmitted(self: *Metrics) void {
        _ = self.transactions_submitted.fetchAdd(1, .monotonic);
    }

    pub fn incTransactionsRejected(self: *Metrics) void {
        _ = self.transactions_rejected.fetchAdd(1, .monotonic);
    }

    pub fn addTransactionsFinalized(self: *Metrics, count: usize) void {
        _ = self.transactions_finalized.fetchAdd(@intCast(count), .monotonic);
    }

    pub fn incBlocksProposed(self: *Metrics) void {
        _ = self.blocks_proposed.fetchAdd(1, .monotonic);
    }

    pub fn incBlocksFinalized(self: *Metrics) void {
        _ = self.blocks_finalized.fetchAdd(1, .monotonic);
    }

    pub fn incVotesReceived(self: *Metrics) void {
        _ = self.consensus_votes_received.fetchAdd(1, .monotonic);
    }

    pub fn addPeerMessageSent(self: *Metrics, bytes: usize) void {
        _ = self.peer_messages_sent.fetchAdd(1, .monotonic);
        _ = self.bytes_sent.fetchAdd(@intCast(bytes), .monotonic);
    }

    pub fn addPeerMessageReceived(self: *Metrics, bytes: usize) void {
        _ = self.peer_messages_received.fetchAdd(1, .monotonic);
        _ = self.bytes_received.fetchAdd(@intCast(bytes), .monotonic);
    }

    pub fn prometheus(self: *const Metrics, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "# HELP aion_transactions_submitted Total transactions accepted into node mempools.\n" ++
            "# TYPE aion_transactions_submitted counter\n" ++
            "aion_transactions_submitted {d}\n" ++
            "# HELP aion_transactions_rejected Total transactions rejected by node admission.\r\n" ++
            "# TYPE aion_transactions_rejected counter\n" ++
            "aion_transactions_rejected {d}\n" ++
            "# HELP aion_transactions_finalized Total transactions committed by certified blocks.\n" ++
            "# TYPE aion_transactions_finalized counter\n" ++
            "aion_transactions_finalized {d}\n" ++
            "# HELP aion_blocks_proposed Total BFT proposals created by this node.\n" ++
            "# TYPE aion_blocks_proposed counter\n" ++
            "aion_blocks_proposed {d}\n" ++
            "# HELP aion_blocks_finalized Total blocks finalized by this node.\n" ++
            "# TYPE aion_blocks_finalized counter\n" ++
            "aion_blocks_finalized {d}\n" ++
            "# HELP aion_consensus_votes_received Total consensus votes received.\n" ++
            "# TYPE aion_consensus_votes_received counter\n" ++
            "aion_consensus_votes_received {d}\n" ++
            "# HELP aion_peer_messages_sent Total peer messages sent.\n" ++
            "# TYPE aion_peer_messages_sent counter\n" ++
            "aion_peer_messages_sent {d}\n" ++
            "# HELP aion_peer_messages_received Total peer messages received.\n" ++
            "# TYPE aion_peer_messages_received counter\n" ++
            "aion_peer_messages_received {d}\n" ++
            "# HELP aion_bytes_sent Total peer bytes sent.\n" ++
            "# TYPE aion_bytes_sent counter\n" ++
            "aion_bytes_sent {d}\n" ++
            "# HELP aion_bytes_received Total peer bytes received.\n" ++
            "# TYPE aion_bytes_received counter\n" ++
            "aion_bytes_received {d}\n", .{
            self.transactions_submitted.load(.monotonic),
            self.transactions_rejected.load(.monotonic),
            self.transactions_finalized.load(.monotonic),
            self.blocks_proposed.load(.monotonic),
            self.blocks_finalized.load(.monotonic),
            self.consensus_votes_received.load(.monotonic),
            self.peer_messages_sent.load(.monotonic),
            self.peer_messages_received.load(.monotonic),
            self.bytes_sent.load(.monotonic),
            self.bytes_received.load(.monotonic),
        });
    }
};

test "metrics expose Prometheus counters" {
    var metrics = Metrics.init();
    metrics.incTransactionsSubmitted();
    metrics.addTransactionsFinalized(3);
    metrics.incBlocksFinalized();
    metrics.addPeerMessageSent(12);

    const output = try metrics.prometheus(std.testing.allocator);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "aion_transactions_submitted 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "aion_transactions_finalized 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "aion_blocks_finalized 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "aion_bytes_sent 12") != null);
}

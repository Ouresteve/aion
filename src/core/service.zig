//! Node service boundary for peer and observability listeners.

const std = @import("std");
const bft = @import("bft.zig");
const http = @import("http.zig");
const network = @import("network.zig");
const node_mod = @import("node.zig");
const tcp = @import("tcp.zig");
const transaction = @import("transaction.zig");

const TRANSACTION_RELAY_CAPACITY: usize = 16_384;

pub const Service = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    node: *node_mod.Node,
    peer_listener: tcp.Listener,
    metrics_listener: tcp.Listener,
    peers: std.ArrayList(Peer),
    relay_queue: []transaction.SettlementTx,
    relay_head: usize,
    relay_tail: usize,
    relay_count: usize,
    relay_mutex: std.Thread.Mutex,
    relay_ready: std.Thread.Condition,
    relay_stopping: bool,
    relay_thread: ?std.Thread,

    pub const Peer = struct {
        host: []const u8,
        port: u16,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        node: *node_mod.Node,
        peer_host: []const u8,
        peer_port: u16,
        metrics_host: []const u8,
        metrics_port: u16,
    ) !Service {
        var peer_listener = try tcp.Listener.init(io, peer_host, peer_port);
        errdefer peer_listener.deinit();
        const metrics_listener = try tcp.Listener.init(io, metrics_host, metrics_port);
        errdefer metrics_listener.deinit();
        const relay_queue = try allocator.alloc(transaction.SettlementTx, TRANSACTION_RELAY_CAPACITY);
        return .{
            .allocator = allocator,
            .io = io,
            .node = node,
            .peer_listener = peer_listener,
            .metrics_listener = metrics_listener,
            .peers = std.ArrayList(Peer).empty,
            .relay_queue = relay_queue,
            .relay_head = 0,
            .relay_tail = 0,
            .relay_count = 0,
            .relay_mutex = .{},
            .relay_ready = .{},
            .relay_stopping = false,
            .relay_thread = null,
        };
    }

    pub fn deinit(self: *Service) void {
        self.stopRelayWorker();
        self.allocator.free(self.relay_queue);
        self.metrics_listener.deinit();
        self.peer_listener.deinit();
        self.peers.deinit(self.allocator);
    }

    pub fn addPeer(self: *Service, host: []const u8, port: u16) !void {
        try self.peers.append(self.allocator, .{ .host = host, .port = port });
    }

    /// Starts the single bounded relay worker after peer configuration is
    /// complete. Keeping peer I/O out of client-facing connection threads makes
    /// admission latency independent of temporary peer stalls.
    pub fn startRelayWorker(self: *Service) !void {
        if (self.relay_thread != null) return error.RelayWorkerAlreadyStarted;
        self.relay_thread = try std.Thread.spawn(.{}, relayLoop, .{self});
    }

    fn stopRelayWorker(self: *Service) void {
        self.relay_mutex.lock();
        self.relay_stopping = true;
        self.relay_ready.broadcast();
        self.relay_mutex.unlock();
        if (self.relay_thread) |thread| {
            thread.join();
            self.relay_thread = null;
        }
    }

    fn enqueueTransaction(self: *Service, tx: transaction.SettlementTx) !void {
        self.relay_mutex.lock();
        defer self.relay_mutex.unlock();
        if (self.relay_stopping) return error.RelayWorkerStopped;
        if (self.relay_count == self.relay_queue.len) return error.RelayQueueFull;

        self.relay_queue[self.relay_tail] = tx;
        self.relay_tail = (self.relay_tail + 1) % self.relay_queue.len;
        self.relay_count += 1;
        self.relay_ready.signal();
    }

    fn relayLoop(self: *Service) void {
        while (true) {
            self.relay_mutex.lock();
            while (self.relay_count == 0 and !self.relay_stopping) {
                self.relay_ready.wait(&self.relay_mutex);
            }
            if (self.relay_count == 0 and self.relay_stopping) {
                self.relay_mutex.unlock();
                return;
            }
            const tx = self.relay_queue[self.relay_head];
            self.relay_head = (self.relay_head + 1) % self.relay_queue.len;
            self.relay_count -= 1;
            self.relay_mutex.unlock();

            self.broadcastTransaction(tx);
        }
    }

    /// Relay a newly admitted transaction through the validator mesh. Each
    /// recipient relays only its first copy; duplicates terminate naturally at
    /// mempool admission, which prevents an unbounded gossip loop.
    fn broadcastTransaction(self: *Service, tx: transaction.SettlementTx) void {
        for (self.peers.items) |peer| {
            {
                const stream = tcp.connect(self.io, peer.host, peer.port) catch |err| {
                    std.log.err("transaction relay connection failed: {s}", .{@errorName(err)});
                    continue;
                };
                defer stream.close(self.io);
                tcp.send(self.io, stream, self.allocator, .{ .transaction = tx }) catch |err| {
                    std.log.err("transaction relay failed: {s}", .{@errorName(err)});
                };
            }
        }
    }

    fn handlePeerMessage(self: *Service, message: network.Message) !void {
        switch (message) {
            .transaction => |tx| {
                _ = self.node.submitTransaction(tx) catch |err| {
                    if (err == error.DuplicateTransaction) return;
                    return err;
                };
                try self.enqueueTransaction(tx);
            },
            else => try self.node.handleMessage(message),
        }
    }

    pub fn broadcastProposal(self: *Service, proposed: *node_mod.ProposedBlock) !void {
        try self.node.beginVoteCollection(proposed.*);
        const local_vote = try self.node.voteForProposal(proposed.block, proposed.proposal);
        var certificate = try self.node.collectVote(local_vote);
        defer if (certificate) |*value| value.deinit();

        for (self.peers.items) |peer| {
            const stream = try tcp.connect(self.io, peer.host, peer.port);
            defer stream.close(self.io);
            try tcp.sendBlock(self.io, stream, self.allocator, proposed.block);
            try tcp.send(self.io, stream, self.allocator, .{ .proposal = proposed.proposal });

            var read_buffer: [4096]u8 = undefined;
            var reader = stream.reader(self.io, &read_buffer);
            const frame = try tcp.receiveFrameFromReader(&reader.interface, self.allocator);
            switch (frame) {
                .message => |message| switch (message) {
                    .vote => |vote| {
                        if (try self.node.collectVote(vote)) |new_certificate| {
                            if (certificate) |*old| old.deinit();
                            certificate = new_certificate;
                        }
                    },
                    else => return error.ExpectedVote,
                },
                .block => |block| {
                    var unexpected_block = block;
                    unexpected_block.deinit(self.allocator);
                    return error.ExpectedVote;
                },
                .finalized => |finalized| {
                    var unexpected_finalization = finalized;
                    unexpected_finalization.deinit();
                    return error.ExpectedVote;
                },
            }
        }

        if (certificate) |*value| {
            try self.node.finalizeBlock(proposed, value.*);
            self.broadcastFinalization(proposed, value.*);
        } else {
            return error.QuorumNotReached;
        }
    }

    fn broadcastFinalization(self: *Service, proposed: *node_mod.ProposedBlock, certificate: bft.QuorumCertificate) void {
        for (self.peers.items) |peer| {
            const stream = tcp.connect(self.io, peer.host, peer.port) catch |err| {
                std.log.err("finalization connection failed: {s}", .{@errorName(err)});
                continue;
            };
            defer stream.close(self.io);
            tcp.sendFinalized(self.io, stream, self.allocator, proposed.block, proposed.proposal, certificate) catch |err| {
                std.log.err("finalization broadcast failed: {s}", .{@errorName(err)});
            };
        }
    }

    pub fn servePeerOnce(self: *Service) !void {
        const stream = try self.peer_listener.accept();
        const thread = std.Thread.spawn(.{}, servePeerConnection, .{ self, stream }) catch |err| {
            stream.close(self.io);
            return err;
        };
        thread.detach();
    }

    fn servePeerConnection(self: *Service, stream: std.Io.net.Stream) void {
        defer stream.close(self.io);

        var read_buffer: [4096]u8 = undefined;
        var reader = stream.reader(self.io, &read_buffer);
        while (true) {
            const frame = tcp.receiveFrameFromReader(&reader.interface, self.allocator) catch |err| switch (err) {
                error.EndOfStream => break,
                else => {
                    std.log.err("peer frame failed: {s}", .{@errorName(err)});
                    return;
                },
            };
            self.node.metrics.addPeerMessageReceived(0);
            switch (frame) {
                .block => |block| self.node.acceptBlock(block) catch |err| {
                    var rejected_block = block;
                    rejected_block.deinit(self.allocator);
                    std.log.err("peer block rejected: {s}", .{@errorName(err)});
                    return;
                },
                .message => |message| self.handlePeerMessage(message) catch |err| {
                    std.log.err("peer message rejected: {s}", .{@errorName(err)});
                    return;
                },
                .finalized => |finalized| self.node.acceptFinalized(finalized) catch |err| {
                    std.log.err("finalized block rejected: {s}", .{@errorName(err)});
                    return;
                },
            }
            if (self.node.takePendingVote() catch |err| {
                std.log.err("peer message rejected: {s}", .{@errorName(err)});
                return;
            }) |vote| {
                tcp.send(self.io, stream, self.allocator, .{ .vote = vote }) catch |err| {
                    std.log.err("vote send failed: {s}", .{@errorName(err)});
                    return;
                };
            }
        }
    }

    pub fn serveMetricsOnce(self: *Service) !void {
        const stream = try self.metrics_listener.accept();
        defer stream.close(self.io);
        try http.serveMetricsConnection(self.io, stream, self.allocator, &self.node.metrics);
    }
};

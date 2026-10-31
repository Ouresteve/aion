const std = @import("std");
const aion = @import("aion");
const core = aion.core;

const BlockProducerContext = struct {
    io: std.Io,
    node: *core.Node,
    service: *core.Service,
    timestamp: u64,
    batch_size: usize,
};

const HostPort = struct {
    host: []const u8,
    port: u16,
};

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();

    if (args.next()) |command| {
        if (std.mem.eql(u8, command, "node")) {
            const node_id = try nextCount(&args, 0);
            var listen_host: []const u8 = "0.0.0.0";
            var listen_port: u16 = 7000;
            var metrics_host: []const u8 = "127.0.0.1";
            var metrics_port: u16 = 9000;
            var peer_hosts: [8][]const u8 = undefined;
            var peer_ports: [8]u16 = undefined;
            var peer_count: usize = 0;

            while (args.next()) |arg| {
                if (std.mem.eql(u8, arg, "--listen")) {
                    const value = args.next() orelse return error.MissingListenAddress;
                    const parsed = try parseHostPort(value, 7000);
                    listen_host = parsed.host;
                    listen_port = parsed.port;
                } else if (std.mem.eql(u8, arg, "--metrics")) {
                    const value = args.next() orelse return error.MissingMetricsAddress;
                    const parsed = try parseHostPort(value, 9000);
                    metrics_host = parsed.host;
                    metrics_port = parsed.port;
                } else if (std.mem.eql(u8, arg, "--peer")) {
                    const value = args.next() orelse return error.MissingPeerAddress;
                    if (peer_count >= peer_hosts.len) return error.TooManyPeers;
                    const parsed = try parseHostPort(value, 7000);
                    peer_hosts[peer_count] = parsed.host;
                    peer_ports[peer_count] = parsed.port;
                    peer_count += 1;
                } else {
                    return error.UnknownNodeOption;
                }
            }

            try runNode(
                init,
                node_id,
                listen_host,
                listen_port,
                metrics_host,
                metrics_port,
                peer_hosts[0..peer_count],
                peer_ports[0..peer_count],
            );
            return;
        }
        if (std.mem.eql(u8, command, "load")) {
            const target = args.next() orelse "127.0.0.1:7000";
            const count = try nextCount(&args, 100);
            const parsed = try parseHostPort(target, 7000);
            try runLoad(init, parsed.host, parsed.port, count);
            return;
        }
        return error.UnknownCommand;
    }

    try runDemo(init);
}

fn runNode(
    init: std.process.Init,
    node_id: u64,
    listen_host: []const u8,
    peer_port: u16,
    metrics_host: []const u8,
    metrics_port: u16,
    peer_hosts: []const []const u8,
    peer_ports: []const u16,
) !void {
    var buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const stdout = &file_writer.interface;
    const allocator = init.gpa;
    if (node_id > 2) return error.InvalidNodeId;

    const node_seed: [32]u8 = @splat(@intCast(node_id + 1));
    const key_pair = try core.KeyPair.generateDeterministic(node_seed);
    const validator_zero_keys = try core.KeyPair.generateDeterministic(@splat(1));
    const validator_one_keys = try core.KeyPair.generateDeterministic(@splat(2));
    const validator_two_keys = try core.KeyPair.generateDeterministic(@splat(3));
    const validators = try core.ValidatorSet.init(allocator, &.{
        .{ .address = core.addressFromPublicKey(validator_zero_keys.public_key), .stake = 1_000_000 },
        .{ .address = core.addressFromPublicKey(validator_one_keys.public_key), .stake = 1_000_000 },
        .{ .address = core.addressFromPublicKey(validator_two_keys.public_key), .stake = 1_000_000 },
    });
    var node = try core.Node.init(allocator, 0, key_pair, validators, 10_000);
    defer node.deinit();

    const sender_keys = try core.KeyPair.generateDeterministic(@splat(9));
    const sender = core.addressFromPublicKey(sender_keys.public_key);
    (try node.chain.state.getOrCreate(sender)).balance = core.toMicro(1_000_000);

    var service = try core.Service.init(
        allocator,
        init.io,
        &node,
        listen_host,
        peer_port,
        metrics_host,
        metrics_port,
    );
    defer service.deinit();

    for (peer_hosts, peer_ports) |host, port| {
        try service.addPeer(host, port);
    }

    try stdout.print("Aion node started\n", .{});
    try stdout.print("Listen:  {s}:{d}\n", .{ listen_host, peer_port });
    try stdout.print("Metrics: http://{s}:{d}/metrics\n", .{ metrics_host, metrics_port });
    for (peer_hosts, peer_ports) |host, port| {
        try stdout.print("Peer:    {s}:{d}\n", .{ host, port });
    }
    try stdout.flush();

    const metrics_thread = try std.Thread.spawn(.{}, metricsLoop, .{&service});
    metrics_thread.detach();
    var block_context = BlockProducerContext{
        .io = init.io,
        .node = &node,
        .service = &service,
        .timestamp = 1,
        .batch_size = 100,
    };
    const block_thread = try std.Thread.spawn(.{}, blockProductionLoop, .{&block_context});
    block_thread.detach();
    while (true) {
        service.servePeerOnce() catch |err| {
            std.log.err("peer connection failed: {s}", .{@errorName(err)});
        };
    }
}

fn runLoad(init: std.process.Init, host: []const u8, peer_port: u16, count: u64) !void {
    const allocator = init.gpa;
    const sender_keys = try core.KeyPair.generateDeterministic(@splat(9));
    const sender = core.addressFromPublicKey(sender_keys.public_key);
    const receiver_keys = try core.KeyPair.generateDeterministic(@splat(3));
    const receiver = core.addressFromPublicKey(receiver_keys.public_key);
    const stream = try core.tcpConnect(init.io, host, peer_port);
    defer stream.close(init.io);

    var index: u64 = 0;
    while (index < count) : (index += 1) {
        var tx = core.SettlementTx{
            .from = sender,
            .to = receiver,
            .amount = 1,
            .nonce = index,
        };
        try tx.sign(sender_keys);
        try core.tcpSend(init.io, stream, allocator, .{ .transaction = tx });
    }

    var buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    try file_writer.interface.print("Submitted {d} signed transactions to {s}:{d}\n", .{ count, host, peer_port });
    try file_writer.interface.flush();
}

fn metricsLoop(service: *core.Service) void {
    while (true) {
        service.serveMetricsOnce() catch |err| {
            std.log.err("metrics connection failed: {s}", .{@errorName(err)});
        };
    }
}

fn blockProductionLoop(context: *BlockProducerContext) void {
    while (true) {
        if (context.node.pendingCount() >= context.batch_size) {
            if (context.node.validators.validators.len == 1) {
                if (context.node.finalizePendingSingleValidator(context.timestamp, core.MAX_BLOCK_TRANSACTIONS)) |finalized| {
                    if (finalized) context.timestamp += 1;
                } else |err| {
                    std.log.err("block production failed: {s}", .{@errorName(err)});
                }
            } else if (context.node.proposeBlock(context.timestamp, core.MAX_BLOCK_TRANSACTIONS)) |proposed| {
                var owned_proposal = proposed;
                defer owned_proposal.deinit();
                context.service.broadcastProposal(&owned_proposal) catch |err| {
                    if (err != error.NotLeader) std.log.err("proposal broadcast failed: {s}", .{@errorName(err)});
                };
                context.timestamp += 1;
            } else |err| {
                if (err != error.NotLeader) std.log.err("block production failed: {s}", .{@errorName(err)});
            }
            context.io.sleep(std.Io.Duration.fromNanoseconds(1_000_000), .awake) catch return;
        } else {
            context.io.sleep(std.Io.Duration.fromNanoseconds(1_000_000), .awake) catch return;
        }
    }
}

fn parseHostPort(value: []const u8, default_port: u16) !HostPort {
    if (std.mem.lastIndexOfScalar(u8, value, ':')) |idx| {
        const host = value[0..idx];
        const port_str = value[idx + 1 ..];
        if (host.len == 0) return error.InvalidHostPort;
        const port = std.fmt.parseInt(u16, port_str, 10) catch return error.InvalidPort;
        return .{ .host = host, .port = port };
    }
    return .{ .host = value, .port = default_port };
}

fn nextCount(args: *std.process.Args.Iterator, default: u64) !u64 {
    const value = args.next() orelse return default;
    return std.fmt.parseInt(u64, value, 10) catch return error.InvalidCount;
}

fn runDemo(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const stdout = &file_writer.interface;

    const allocator = std.heap.page_allocator;

    try stdout.print("=== Aion Settlement Engine ===\n", .{});
    try stdout.print("Version: {s}\n\n", .{aion.version});

    const alice_keys = core.generateKeyPair(init.io);
    const bob_keys = core.generateKeyPair(init.io);

    const alice = core.addressFromPublicKey(alice_keys.public_key);
    const bob = core.addressFromPublicKey(bob_keys.public_key);

    try stdout.print("Generated real Ed25519 key pairs for Alice and Bob\n\n", .{});

    var state = core.State.init(allocator);
    defer state.deinit();

    {
        const alice_acc = try state.getOrCreate(alice);
        alice_acc.balance = core.toMicro(1000);
    }

    try stdout.print("Before transfer:\n", .{});
    try printBalance(stdout, "Alice", state.get(alice).?);
    try printBalance(stdout, "Bob  ", state.get(bob) orelse core.Account.init());
    try stdout.print("\n", .{});

    var tx = core.SettlementTx{
        .from = alice,
        .to = bob,
        .amount = core.toMicro(250),
        .nonce = 0,
    };

    try tx.sign(alice_keys);
    try stdout.print("Transaction signed with Alice's private key\n", .{});

    try state.applyTransaction(tx);
    try stdout.print("Transaction verified and applied successfully\n\n", .{});

    try stdout.print("After transfer:\n", .{});
    try printBalance(stdout, "Alice", state.get(alice).?);
    try printBalance(stdout, "Bob  ", state.get(bob).?);

    try stdout.flush();
}

fn printBalance(writer: anytype, name: []const u8, acc: core.Account) !void {
    const whole = acc.balance / core.MICRO_PER_AION;
    const fraction = acc.balance % core.MICRO_PER_AION;
    try writer.print("  {s}: {d}.{d:0>6} Aion  (nonce: {d})\n", .{ name, whole, fraction, acc.nonce });
}

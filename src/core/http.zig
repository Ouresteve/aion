//! HTTP metrics endpoint for Prometheus scraping.

const std = @import("std");
const metrics_mod = @import("metrics.zig");

const net = std.Io.net;

pub fn serveMetricsConnection(
    io: std.Io,
    stream: net.Stream,
    allocator: std.mem.Allocator,
    metrics: *const metrics_mod.Metrics,
) !void {
    var request_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &request_buffer);
    const request = try reader.interface.takeDelimiterExclusive('\n');

    const is_metrics_request = std.mem.startsWith(u8, request, "GET /metrics ") or
        std.mem.startsWith(u8, request, "GET /metrics?");
    if (is_metrics_request) {
        const body = try metrics.prometheus(allocator);
        defer allocator.free(body);
        try writeResponse(io, stream, allocator, "200 OK", "text/plain; version=0.0.4", body);
    } else {
        try writeResponse(io, stream, allocator, "404 Not Found", "text/plain", "not found\n");
    }
}

fn writeResponse(
    io: std.Io,
    stream: net.Stream,
    allocator: std.mem.Allocator,
    status: []const u8,
    content_type: []const u8,
    body: []const u8,
) !void {
    const response = try std.fmt.allocPrint(
        allocator,
        "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ status, content_type, body.len, body },
    );
    defer allocator.free(response);

    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll(response);
    try writer.interface.flush();
}

test "metrics endpoint identifies the Prometheus route" {
    var metrics = metrics_mod.Metrics.init();
    metrics.incBlocksFinalized();
    const body = try metrics.prometheus(std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "aion_blocks_finalized 1") != null);
}

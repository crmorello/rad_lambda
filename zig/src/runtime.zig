//! Minimal AWS Lambda custom runtime loop (the Runtime API is plain local
//! HTTP): GET the next invocation, run the handler, POST result or error.
const std = @import("std");
const handler = @import("handler.zig");

const API_VERSION = "2018-06-01";

pub fn run(alloc: std.mem.Allocator, api: []const u8) !void {
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var client: std.http.Client = .{ .allocator = alloc, .io = io };
    defer client.deinit();

    const next_url = try std.fmt.allocPrint(alloc, "http://{s}/" ++ API_VERSION ++ "/runtime/invocation/next", .{api});
    defer alloc.free(next_url);
    const next_uri = try std.Uri.parse(next_url);

    while (true) {
        var req = try client.request(.GET, next_uri, .{});
        defer req.deinit();
        try req.sendBodiless();
        var redirect_buf: [1024]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);

        var request_id_buf: [128]u8 = undefined;
        var request_id: []const u8 = "";
        var header_it = response.head.iterateHeaders();
        while (header_it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "Lambda-Runtime-Aws-Request-Id")) {
                request_id = request_id_buf[0..h.value.len];
                @memcpy(request_id_buf[0..h.value.len], h.value);
            }
        }

        var transfer_buf: [8192]u8 = undefined;
        const body = try response.reader(&transfer_buf).allocRemaining(alloc, .unlimited);
        defer alloc.free(body);

        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        if (handler.handleEvent(arena, body)) |result| {
            // one summary line per invocation — success is otherwise silent
            std.debug.print("ok {s} {s}\n", .{ request_id, result });
            try post(&client, alloc, api, request_id, "response", result);
        } else |err| {
            std.debug.print("invocation {s} failed: {s}\n", .{ request_id, @errorName(err) });
            const msg = try std.fmt.allocPrint(arena, "{{\"errorMessage\":\"{s}\",\"errorType\":\"Error\"}}", .{@errorName(err)});
            try post(&client, alloc, api, request_id, "error", msg);
        }
    }
}

fn post(client: *std.http.Client, alloc: std.mem.Allocator, api: []const u8, request_id: []const u8, kind: []const u8, body: []const u8) !void {
    const url = try std.fmt.allocPrint(alloc, "http://{s}/" ++ API_VERSION ++ "/runtime/invocation/{s}/{s}", .{ api, request_id, kind });
    defer alloc.free(url);
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
    });
    _ = result;
}

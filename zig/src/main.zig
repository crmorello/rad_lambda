//! Entry point. In a Lambda container (AWS_LAMBDA_RUNTIME_API set) it runs
//! the runtime loop handling S3 notifications; locally it's a CLI:
//!
//!   rad_lambda <grib(.gz) | dir> [out_dir]    # out_dir defaults to <dir>/rads
const std = @import("std");
const gdal = @import("gdal.zig");
const handler = @import("handler.zig");
const obs = @import("obs.zig");
const runtime = @import("runtime.zig");
const manifest = @import("manifest.zig");

/// std.log defaults to .err in ReleaseFast — which silently compiled the
/// flow producer's info/warn lines OUT of the deployed binary. Everything
/// this lambda logs is one short line per event; keep .info in all modes
/// (stderr -> CloudWatch).
pub const std_options: std.Options = .{ .log_level = .info };

pub fn main(init: std.process.Init.Minimal) !void {
    const alloc = std.heap.c_allocator;
    gdal.setup();

    // Comma-separated public buckets to read anonymously (both modes),
    // e.g. RAD_UNSIGNED_BUCKETS=noaa-mrms-pds
    if (handler.getenv("RAD_UNSIGNED_BUCKETS")) |buckets| {
        var it = std.mem.splitScalar(u8, buckets, ',');
        while (it.next()) |bucket| {
            if (bucket.len > 0) try gdal.markBucketUnsigned(alloc, bucket);
        }
    }

    // .flw sidecar production (both modes; the CLI's ascending-stamp walk
    // means each frame's predecessor is already on disk when its turn comes).
    if (handler.getenv("RAD_FLOW")) |v| {
        if (std.mem.eql(u8, v, "0")) handler.flow_enabled = false;
    }

    if (handler.getenv("AWS_LAMBDA_RUNTIME_API")) |api| {
        // Store gzipped bodies with Content-Encoding metadata (RAD_GZIP=0 opts out).
        const gz = handler.getenv("RAD_GZIP") orelse "1";
        if (!std.mem.eql(u8, gz, "0")) {
            handler.gzip_output = true;
            try gdal.markPrefixGzip(alloc, try handler.outputDir());
        }
        return runtime.run(alloc, api);
    }

    var args_it = std.process.Args.Iterator.init(init.args);
    _ = args_it.next(); // argv0
    const maybe_input = args_it.next();
    const maybe_out = args_it.next();

    const input = maybe_input orelse {
        std.debug.print("Usage: rad_lambda <grib(.gz) | dir> [out_dir]\n" ++
            "       rad_lambda --obs <obs.parquet> [out_dir]\n", .{});
        std.process.exit(1);
    };

    // Observation surface (H3 parquet) -> obs/<variable>/ products. CLI-only
    // for now; the S3 trigger for .parquet keys is a later hook in handleEvent.
    if (std.mem.eql(u8, input, "--obs")) {
        const parquet = maybe_out orelse {
            std.debug.print("Usage: rad_lambda --obs <obs.parquet> [out_dir]\n", .{});
            std.process.exit(1);
        };
        const out_dir = args_it.next() orelse (std.fs.path.dirname(parquet) orelse ".");
        const written = try obs.ingest(alloc, parquet, out_dir, handler.resolution());
        defer {
            for (written) |w| alloc.free(w.path);
            alloc.free(written);
        }
        for (written) |w| printOut("{s} ({d} bytes)\n", .{ w.path, w.bytes });
        printOut("Wrote {d} obs file(s) under {s}/obs\n", .{ written.len, std.mem.trimEnd(u8, out_dir, "/") });
        return;
    }

    if (gdal.isDir(alloc, input)) {
        const out_dir = maybe_out orelse try std.fmt.allocPrint(alloc, "{s}/rads", .{input});
        const names = try gdal.readDir(alloc, input);
        defer {
            for (names) |n| alloc.free(n);
            alloc.free(names);
        }
        var files: std.ArrayList([]const u8) = .empty;
        defer files.deinit(alloc);
        for (names) |name| {
            if (std.mem.endsWith(u8, name, ".grib2") or
                std.mem.endsWith(u8, name, ".grb2") or
                std.mem.endsWith(u8, name, ".grib2.gz"))
            {
                try files.append(alloc, name);
            }
        }
        std.mem.sort([]const u8, files.items, {}, lessThan);
        for (files.items) |name| {
            const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ input, name });
            defer alloc.free(path);
            const written = try handler.processFile(alloc, path, out_dir, handler.resolution(), "");
            defer alloc.free(written);
            printOut("{s}\n", .{written});
        }
        printOut("Wrote {d} RAD file(s) to {s}\n", .{ files.items.len, out_dir });
    } else {
        const out_dir = maybe_out orelse (std.fs.path.dirname(input) orelse ".");
        const written = try handler.processFile(alloc, input, out_dir, handler.resolution(), "");
        defer alloc.free(written);
        printOut("{s}\n", .{written});
    }
}

/// stdout via libc write — sidesteps the std.Io plumbing for two CLI prints.
fn printOut(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

test {
    std.testing.refAllDecls(@This());
}

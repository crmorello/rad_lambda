//! Entry point. In a Lambda container (AWS_LAMBDA_RUNTIME_API set) it runs
//! the runtime loop handling S3 notifications; locally it's a CLI:
//!
//!   rad_lambda <grib(.gz) | dir> [out_dir]    # out_dir defaults to <dir>/rads
const std = @import("std");
const gdal = @import("gdal.zig");
const handler = @import("handler.zig");
const obs = @import("obs.zig");
const tiles = @import("tiles.zig");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
fn c_setenv(name: [:0]const u8, value: []const u8) c_int {
    var buf: [1024]u8 = undefined;
    if (value.len >= buf.len) return -1;
    @memcpy(buf[0..value.len], value);
    buf[value.len] = 0;
    return setenv(name.ptr, buf[0..value.len :0].ptr, 1);
}
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
        //
        // Guarded on RAD_OUTPUT being present: the TILE function is the same
        // image with no output dir at all (it only reads, via RAD_TILES_ROOT),
        // and an unconditional outputDir() here killed it at init with
        // `error.MissingRadOutput` before it served a single request. A
        // producer that is genuinely missing RAD_OUTPUT still fails loudly —
        // at the write, inside handleEvent, where the error names the record.
        const gz = handler.getenv("RAD_GZIP") orelse "1";
        if (!std.mem.eql(u8, gz, "0")) {
            if (handler.getenv("RAD_OUTPUT") != null) {
                handler.gzip_output = true;
                try gdal.markPrefixGzip(alloc, try handler.outputDir());
            }
        }
        return runtime.run(alloc, api);
    }

    var args_it = std.process.Args.Iterator.init(init.args);
    _ = args_it.next(); // argv0
    const maybe_input = args_it.next();
    const maybe_out = args_it.next();

    const input = maybe_input orelse {
        std.debug.print("Usage: rad_lambda <grib(.gz) | dir> [out_dir]\n" ++
            "       rad_lambda --obs <obs.parquet> [out_dir]\n" ++
            "       rad_lambda --flow <rad_dir> <prev_id> <next_id> [out_dir]\n", .{});
        std.process.exit(1);
    };

    // Local dev/QA: regenerate one .flw from two EXISTING .rad files, using
    // today's production FLOW_LOD/FLOW_SEARCH — a visual check before
    // deploying a tuning change (see handler.flowFileFromLocalPair). Point
    // raydare's local dev server at <out_dir> and it'll serve the result.
    if (std.mem.eql(u8, input, "--flow")) {
        const rad_dir = maybe_out orelse {
            std.debug.print("Usage: rad_lambda --flow <rad_dir> <prev_id> <next_id> [out_dir]\n", .{});
            std.process.exit(1);
        };
        const prev_id = args_it.next() orelse std.process.exit(1);
        const next_id = args_it.next() orelse std.process.exit(1);
        const out_dir = args_it.next() orelse rad_dir;
        try handler.flowFileFromLocalPair(alloc, rad_dir, prev_id, next_id, out_dir);
        return;
    }

    // Observation surface (H3 parquet) -> obs/<variable>/ products. CLI-only
    // for now; the S3 trigger for .parquet keys is a later hook in handleEvent.
    // Raster tile to a file: rad_lambda --tile <root> <product> <stamp> <z> <x> <y> [out.png]
    // (<root> = the served root holding rads/ and obs/, local dir or /vsis3/bucket)
    if (std.mem.eql(u8, input, "--tile")) {
        const root = maybe_out orelse {
            std.debug.print("Usage: rad_lambda --tile <root> <product> <stamp> <z> <x> <y> [out.png]\n", .{});
            std.process.exit(1);
        };
        const product = args_it.next() orelse std.process.exit(1);
        const st = args_it.next() orelse std.process.exit(1);
        const z = try std.fmt.parseInt(u32, args_it.next() orelse std.process.exit(1), 10);
        const x = try std.fmt.parseInt(u32, args_it.next() orelse std.process.exit(1), 10);
        const y = try std.fmt.parseInt(u32, args_it.next() orelse std.process.exit(1), 10);
        const out_path = args_it.next() orelse "tile.png";
        // the tile module reads its root from the environment (lambda contract)
        _ = c_setenv("RAD_TILES_ROOT", root);
        try tiles.renderToFile(alloc, .{ .product = product, .stamp = st, .z = z, .x = x, .y = y }, out_path);
        return;
    }

    if (std.mem.eql(u8, input, "--obs")) {
        const parquet = maybe_out orelse {
            std.debug.print("Usage: rad_lambda --obs <obs.parquet> [out_dir]\n", .{});
            std.process.exit(1);
        };
        const out_dir = args_it.next() orelse (std.fs.path.dirname(parquet) orelse ".");
        // CLI: plain bodies, unwindowed manifests — the lambda path passes
        // handler.gzip_output and handler.manifestWindowMs() instead.
        const written = try obs.ingest(alloc, parquet, out_dir, handler.resolution(), false, obs.MANIFEST_WINDOW_MS);
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

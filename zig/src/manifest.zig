//! manifest.json rebuild — always from a LISTING of the output dir, never
//! read-modify-write: concurrent region invocations would permanently lose
//! each other's appends, while list-based rebuild is f(bucket state), so
//! last-writer-wins converges. JSON shape (and byte layout) matches the
//! Crystal implementation and the Go dev server.
const std = @import("std");
const stamp = @import("stamp.zig");
const gdal = @import("gdal.zig");

pub const Frame = struct {
    id: []const u8,
    bytes: u64,
    /// Overrides the manifest-wide prefix for this frame. The radar TILE
    /// timeline interleaves the 10-minute frames in rads/ with the 5-minute
    /// in-betweens in rads/5min/, and neither set is duplicated on disk — so
    /// one manifest has to carry urls from two prefixes.
    url_prefix: ?[]const u8 = null,
};

fn frameLessThan(_: void, a: Frame, b: Frame) bool {
    const sa = stamp.stampOfId(a.id);
    const sb = stamp.stampOfId(b.id);
    return switch (std.mem.order(u8, sa, sb)) {
        .lt => true,
        .gt => false,
        .eq => std.mem.order(u8, a.id, b.id) == .lt,
    };
}

/// Manifest JSON for a set of frames. `url_prefix` is the serving path of
/// the output dir ("" or "/rads" — no trailing slash); `product` names the
/// field ("reflectivity", or an obs variable). `bytes` is the stored object
/// size (gzipped when gzip-at-rest is on) — i.e. transfer size.
pub fn build(alloc: std.mem.Allocator, frames: []Frame, url_prefix: []const u8, product: []const u8) ![]u8 {
    std.mem.sort(Frame, frames, {}, frameLessThan);

    var aw: std.Io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.print("{{\"product\":\"{s}\",\"updated_at\":\"", .{product});
    if (frames.len > 0) {
        var last: stamp.Stamp = undefined;
        @memcpy(&last.text, stamp.stampOfId(frames[frames.len - 1].id)[0..15]);
        try w.writeAll(&last.rfc3339());
    }
    try w.writeAll("\",\"frames\":[");
    for (frames, 0..) |frame, i| {
        if (i > 0) try w.writeAll(",");
        var s: stamp.Stamp = undefined;
        @memcpy(&s.text, stamp.stampOfId(frame.id)[0..15]);
        try w.print("{{\"id\":\"{s}\",\"time\":\"{s}\",\"url\":\"{s}/{s}.rad\",\"bytes\":{d}}}", .{
            frame.id, &s.rfc3339(), frame.url_prefix orelse url_prefix, frame.id, frame.bytes,
        });
    }
    try w.writeAll("]}");
    return aw.toOwnedSlice();
}

/// True if `id`'s stamp is within the window ending at `now_ms`.
/// `window_ms` <= 0 means unwindowed (everything is fresh).
pub fn frameFresh(id: []const u8, now_ms: i64, window_ms: i64) bool {
    if (window_ms <= 0) return true;
    var s: stamp.Stamp = undefined;
    @memcpy(&s.text, stamp.stampOfId(id)[0..15]);
    return s.ms() >= now_ms - window_ms;
}

/// List the output dir, rebuild, write manifest.json alongside the RADs.
/// Only frames whose STAMP falls inside `window_ms` (ending now) are listed —
/// older RADs stay in the bucket (fetchable by URL until lifecycle expiry),
/// they just leave the timeline the client sees.
pub fn rebuild(alloc: std.mem.Allocator, out_dir: []const u8, url_prefix: []const u8, product: []const u8, gzip: bool, window_ms: i64) !void {
    const dir = std.mem.trimEnd(u8, out_dir, "/");
    const path = try std.fmt.allocPrint(alloc, "{s}/manifest.json", .{dir});
    defer alloc.free(path);
    try rebuildFrom(alloc, path, &.{.{ .dir = dir, .url_prefix = url_prefix }}, product, gzip, window_ms);
}

/// One prefix contributing frames to a manifest.
pub const Source = struct { dir: []const u8, url_prefix: []const u8 };

/// Rebuild from SEVERAL prefixes into an explicit path. `rebuild` is the
/// one-source case; the radar tile timeline is the two-source case, drawing
/// 10-minute frames from rads/ and 5-minute ones from rads/5min/ without
/// copying either. Frames are sorted by `build`, so sources may be listed in
/// any order and still interleave correctly by stamp.
pub fn rebuildFrom(alloc: std.mem.Allocator, out_path: []const u8, sources: []const Source, product: []const u8, gzip: bool, window_ms: i64) !void {
    const now_ms = @as(i64, gdal.c.time(null)) * 1000;
    var frames: std.ArrayList(Frame) = .empty;
    defer frames.deinit(alloc);

    var owned: std.ArrayList([]const u8) = .empty;
    defer {
        for (owned.items) |n| alloc.free(n);
        owned.deinit(alloc);
    }

    for (sources) |src| {
        const dir = std.mem.trimEnd(u8, src.dir, "/");
        // vsicurl caches directory listings per process; a warm container would
        // otherwise rebuild from the frame set it saw at first listing, forever.
        gdal.clearVsiCache(alloc, dir);
        const entries = try gdal.readDirEntries(alloc, dir);
        defer alloc.free(entries);
        for (entries) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".rad")) {
                alloc.free(entry.name);
                continue;
            }
            const id = entry.name[0 .. entry.name.len - 4];
            if (!stamp.validId(id) or !frameFresh(id, now_ms, window_ms)) {
                alloc.free(entry.name);
                continue;
            }
            // entry.name outlives the loop: `id` borrows it and `build` reads it.
            try owned.append(alloc, entry.name);
            try frames.append(alloc, .{ .id = id, .bytes = entry.size, .url_prefix = src.url_prefix });
        }
    }

    const json = try build(alloc, frames.items, sources[0].url_prefix, product);
    defer alloc.free(json);
    const body = if (gzip) try gzipBytes(alloc, json) else json;
    defer if (gzip) alloc.free(body);
    try gdal.vsiWrite(alloc, out_path, body);
}

/// Gzip in memory (transport compression at rest: stored gzipped with
/// Content-Encoding metadata so HTTP clients inflate transparently).
pub fn gzipBytes(alloc: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const flate = std.compress.flate;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try aw.ensureUnusedCapacity(4096); // Compress.init asserts output buffer > 8
    const window = try alloc.alloc(u8, flate.max_window_len);
    defer alloc.free(window);
    var compress: flate.Compress = try .init(&aw.writer, window, .gzip, .default);
    try compress.writer.writeAll(bytes);
    try compress.finish();
    return aw.toOwnedSlice();
}

/// Inverse of gzipBytes, for reading gzip-at-rest objects back (the .flw
/// producer re-reads the previous slice's .rad). Takes OWNERSHIP of `bytes`:
/// returned unchanged when not gzip, otherwise freed and replaced by the
/// inflated copy.
pub fn gunzipIfNeeded(alloc: std.mem.Allocator, bytes: []u8) ![]u8 {
    if (bytes.len < 2 or bytes[0] != 0x1f or bytes[1] != 0x8b) return bytes;
    errdefer alloc.free(bytes);
    const flate = std.compress.flate;
    var in: std.Io.Reader = .fixed(bytes);
    const window = try alloc.alloc(u8, flate.max_window_len);
    defer alloc.free(window);
    var d: flate.Decompress = .init(&in, .gzip, window);
    const out = try d.reader.allocRemaining(alloc, .unlimited);
    alloc.free(bytes);
    return out;
}

test "gzip round trip (at-rest transport helpers)" {
    const alloc = std.testing.allocator;
    const original = "RAD2 pretend payload, repetitive repetitive repetitive";
    const zipped = try gzipBytes(alloc, original);
    // gunzip takes ownership of its input
    const back = try gunzipIfNeeded(alloc, zipped);
    defer alloc.free(back);
    try std.testing.expectEqualStrings(original, back);
    // non-gzip passes through untouched (same pointer)
    const plain = try alloc.dupe(u8, original);
    const same = try gunzipIfNeeded(alloc, plain);
    defer alloc.free(same);
    try std.testing.expect(same.ptr == plain.ptr);
}

test "manifest json shape (crystal-derived, plus real byte sizes)" {
    const alloc = std.testing.allocator;
    // frames deliberately unsorted; alaska sorts after the bare conus id with
    // the same stamp (secondary sort on the full id).
    var frames = [_]Frame{
        .{ .id = "alaska_20260714-174000", .bytes = 643850 },
        .{ .id = "20260714-175000", .bytes = 718848 },
        .{ .id = "20260714-174000", .bytes = 704166 },
    };
    const json = try build(alloc, &frames, "/rads", "reflectivity");
    defer alloc.free(json);
    try std.testing.expectEqualStrings(
        "{\"product\":\"reflectivity\",\"updated_at\":\"2026-07-14T17:50:00Z\",\"frames\":[" ++
            "{\"id\":\"20260714-174000\",\"time\":\"2026-07-14T17:40:00Z\",\"url\":\"/rads/20260714-174000.rad\",\"bytes\":704166}," ++
            "{\"id\":\"alaska_20260714-174000\",\"time\":\"2026-07-14T17:40:00Z\",\"url\":\"/rads/alaska_20260714-174000.rad\",\"bytes\":643850}," ++
            "{\"id\":\"20260714-175000\",\"time\":\"2026-07-14T17:50:00Z\",\"url\":\"/rads/20260714-175000.rad\",\"bytes\":718848}]}",
        json,
    );

    const empty = try build(alloc, &.{}, "", "reflectivity");
    defer alloc.free(empty);
    try std.testing.expectEqualStrings("{\"product\":\"reflectivity\",\"updated_at\":\"\",\"frames\":[]}", empty);
}

test "frame freshness window" {
    // 2026-08-05T02:00:00Z in ms
    const now_ms: i64 = 1785895200000;
    const h3 = 3 * std.time.ms_per_hour;
    try std.testing.expect(frameFresh("20260805-020000", now_ms, h3)); // on the edge of now
    try std.testing.expect(frameFresh("alaska_20260804-231000", now_ms, h3)); // 2h50m old
    try std.testing.expect(!frameFresh("20260804-225000", now_ms, h3)); // 3h10m old
    try std.testing.expect(frameFresh("20260710-000000", now_ms, 0)); // unwindowed keeps all
}

test "gzip round trip" {
    const alloc = std.testing.allocator;
    const original = "the quick brown fox jumps over the lazy dog, twice: the quick brown fox";
    const zipped = try gzipBytes(alloc, original);
    defer alloc.free(zipped);
    try std.testing.expect(zipped.len >= 2 and zipped[0] == 0x1f and zipped[1] == 0x8b);

    var in: std.Io.Reader = .fixed(zipped);
    var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&in, .gzip, &decompress_buf);
    var out: [original.len]u8 = undefined;
    try decompress.reader.readSliceAll(&out);
    try std.testing.expectEqualStrings(original, &out);
}

test "build: per-frame url_prefix interleaves two prefixes in one manifest" {
    const alloc = std.testing.allocator;
    // The radar tile timeline: 10-minute frames served from /rads, the
    // in-between slots from /rads/5min, sorted into one timeline by stamp.
    var frames = [_]Frame{
        .{ .id = "20260712-011000", .bytes = 500 },
        .{ .id = "20260712-010500", .bytes = 400, .url_prefix = "/rads/5min" },
        .{ .id = "20260712-011500", .bytes = 450, .url_prefix = "/rads/5min" },
        .{ .id = "alaska_20260712-010500", .bytes = 90, .url_prefix = "/rads/5min" },
        .{ .id = "20260712-010000", .bytes = 520 },
    };
    const json = try build(alloc, &frames, "/rads", "reflectivity");
    defer alloc.free(json);

    // Frames with no override keep the manifest-wide prefix...
    try std.testing.expect(std.mem.indexOf(u8, json, "\"url\":\"/rads/20260712-011000.rad\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"url\":\"/rads/20260712-010000.rad\"") != null);
    // ...and the fills carry their own, region prefix included.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"url\":\"/rads/5min/20260712-010500.rad\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"url\":\"/rads/5min/alaska_20260712-010500.rad\"") != null);
    // No fill leaked onto the 10-minute prefix.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"url\":\"/rads/20260712-010500.rad\"") == null);

    // build() sorts, so sources may be listed in any order: the timeline must
    // come out 0000, 0500, 0500(alaska), 1000, 1500 by stamp.
    const at0 = std.mem.indexOf(u8, json, "20260712-010000").?;
    const at5 = std.mem.indexOf(u8, json, "20260712-010500").?;
    const at10 = std.mem.indexOf(u8, json, "20260712-011000").?;
    const at15 = std.mem.indexOf(u8, json, "20260712-011500").?;
    try std.testing.expect(at0 < at5 and at5 < at10 and at10 < at15);
}

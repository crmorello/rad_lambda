//! Raster tile endpoint: GET /tiles/v1/<product>/<stamp>/<z>/<x>/<y>.png
//! rendered on demand from the RAD3 frames in the bucket (radcore tile.zig),
//! meant to sit behind CloudFront so every tile is rendered once per stamp.
//!
//!   <product>  registry id: rads, obs/temperature, …
//!   <stamp>    20260901-205500, or `latest` → 302 to the newest stamp
//!   query      tms=1 (flip y), size=256|512, palette=0|1 (radar ramp)
//!   also       /tiles/v1/<product>/manifest.json, /tiles/v1/<product>/timerange
//!
//! Frames are fetched whole (they are gzip-at-rest, so page ranges are not
//! an option) and kept in a warm-container cache keyed by path, so a
//! customer panning around one stamp costs S3 once and ~1–3 ms of render per
//! tile afterwards. RAD_TILES_ROOT points at the served root
//! (`/vsis3/<bucket>` — the dir that holds `rads/` and `obs/`).
const std = @import("std");
const radcore = @import("radcore");
const gdal = @import("gdal.zig");
const manifest = @import("manifest.zig");
const stamp = @import("stamp.zig");
const handler = @import("handler.zig");
const c = gdal.c;
const log = std.log.scoped(.tiles);

const persistent = std.heap.c_allocator;
pub const MAX_ZOOM: u32 = 14;

pub fn root() ![]const u8 {
    return handler.getenv("RAD_TILES_ROOT") orelse error.MissingTilesRoot;
}

// ---------------------------------------------------------------- frame cache

const Cached = struct { path: []u8, bytes: []u8 };
var frame_cache: std.ArrayList(Cached) = .empty;
var frame_cache_bytes: usize = 0;

fn cacheCap() usize {
    const mb: usize = if (handler.getenv("RAD_TILES_CACHE_MB")) |v| (std.fmt.parseInt(usize, v, 10) catch 256) else 256;
    return mb * 1024 * 1024;
}

/// Frame bytes (gunzipped) for `path`, from the cache or S3. Eviction is
/// oldest-first and happens BEFORE a load, so nothing used by the current
/// request disappears mid-render. null = not found.
fn loadFrame(path: []const u8) !?[]const u8 {
    for (frame_cache.items) |e| {
        if (std.mem.eql(u8, e.path, path)) return e.bytes;
    }
    while (frame_cache_bytes > cacheCap() and frame_cache.items.len > 0) {
        const old = frame_cache.orderedRemove(0);
        frame_cache_bytes -= old.bytes.len;
        persistent.free(old.path);
        persistent.free(old.bytes);
    }
    const raw = (try gdal.vsiRead(persistent, path)) orelse return null;
    const bytes = try manifest.gunzipIfNeeded(persistent, raw); // takes ownership of raw
    try frame_cache.append(persistent, .{ .path = try persistent.dupe(u8, path), .bytes = bytes });
    frame_cache_bytes += bytes.len;
    return bytes;
}

// ------------------------------------------------------------ manifest cache

const ManifestFrame = struct { id: []const u8, time: []const u8 = "", url: []const u8 = "", bytes: i64 = 0 };
const Manifest = struct { product: []const u8 = "", updated_at: []const u8 = "", frames: []ManifestFrame = &.{} };
const CachedManifest = struct { product: []u8, text: []u8, at: i64 };
var manifest_cache: std.ArrayList(CachedManifest) = .empty;
const MANIFEST_TTL_S: i64 = 15;

/// Manifest text for a product (15 s cache); null = no such product/manifest.
fn manifestText(product: []const u8) !?[]const u8 {
    const now: i64 = @intCast(c.time(null));
    for (manifest_cache.items) |*e| {
        if (std.mem.eql(u8, e.product, product)) {
            if (now - e.at < MANIFEST_TTL_S) return e.text;
            const path = try std.fmt.allocPrint(persistent, "{s}/{s}/manifest.json", .{ try root(), product });
            defer persistent.free(path);
            gdal.clearVsiCache(persistent, path);
            const raw = (try gdal.vsiRead(persistent, path)) orelse return null;
            persistent.free(e.text);
            e.text = try manifest.gunzipIfNeeded(persistent, raw);
            e.at = now;
            return e.text;
        }
    }
    const path = try std.fmt.allocPrint(persistent, "{s}/{s}/manifest.json", .{ try root(), product });
    defer persistent.free(path);
    const raw = (try gdal.vsiRead(persistent, path)) orelse return null;
    const text = try manifest.gunzipIfNeeded(persistent, raw);
    try manifest_cache.append(persistent, .{ .product = try persistent.dupe(u8, product), .text = text, .at = now });
    return text;
}

fn parseManifest(arena: std.mem.Allocator, text: []const u8) !Manifest {
    return std.json.parseFromSliceLeaky(Manifest, arena, text, .{ .ignore_unknown_fields = true });
}

// ------------------------------------------------------------------ rendering

pub const Request = struct {
    product: []const u8,
    stamp: []const u8,
    z: u32,
    x: u32,
    y: u32,
    size: u32 = 256,
    palette: i32 = 0,
};

pub const Rendered = struct { png: []u8, empty: bool, frames: usize };

var transparent_256: ?[]u8 = null;
var transparent_512: ?[]u8 = null;

fn transparent(size: u32) ![]const u8 {
    const slot = if (size == 512) &transparent_512 else &transparent_256;
    if (slot.*) |t| return t;
    slot.* = try radcore.png.transparent(persistent, size, size);
    return slot.*.?;
}

/// Render one tile from the frames of `stamp` listed in the product manifest.
/// null = unknown product or stamp. The returned png is arena-owned unless
/// it is the shared transparent tile (empty = true) — callers must not free it.
pub fn render(arena: std.mem.Allocator, req: Request) !?Rendered {
    const idx = radcore.products.indexOf(req.product) orelse return null;
    const text = (try manifestText(req.product)) orelse return null;
    const m = try parseManifest(arena, text);
    var files: std.ArrayList(radcore.ZCRadFile) = .empty;
    for (m.frames) |f| {
        if (!std.mem.eql(u8, stamp.stampOfId(f.id), req.stamp)) continue;
        const path = try std.fmt.allocPrint(arena, "{s}{s}", .{ try root(), f.url });
        const bytes = (try loadFrame(path)) orelse {
            log.warn("frame listed but unreadable: {s}", .{path});
            continue;
        };
        const hd = radcore.store.parseRadHeader(bytes) orelse {
            log.warn("bad RAD header: {s}", .{path});
            continue;
        };
        try files.append(arena, .{
            .geo_tran = hd.geo_tran,
            .max_x = hd.max_x,
            .max_y = hd.max_y,
            .original_size = hd.original_size,
            .compressed = bytes.ptr + hd.stream_off,
            .compressed_len = hd.stream_len,
            .rle_version = hd.rle_version,
        });
    }
    if (files.items.len == 0) return null;
    const r = try radcore.tile.renderPNG(arena, files.items, req.z, req.x, req.y, .{
        .size = req.size,
        .product = @intCast(idx),
        .palette = req.palette,
        .kernel = 1,
    });
    if (r.stats.empty) {
        arena.free(r.bytes);
        return .{ .png = @constCast(try transparent(req.size)), .empty = true, .frames = files.items.len };
    }
    return .{ .png = r.bytes, .empty = false, .frames = files.items.len };
}

/// Newest stamp in the product manifest (for `latest`).
fn newestStamp(arena: std.mem.Allocator, product: []const u8) !?[]const u8 {
    const text = (try manifestText(product)) orelse return null;
    const m = try parseManifest(arena, text);
    var best: ?[]const u8 = null;
    for (m.frames) |f| {
        const s = stamp.stampOfId(f.id);
        if (best == null or std.mem.order(u8, s, best.?) == .gt) best = s;
    }
    return best;
}

// ----------------------------------------------------------------- HTTP glue

const Response = struct {
    status: u16,
    content_type: []const u8 = "text/plain",
    cache_control: []const u8 = "no-store",
    body: []const u8 = "",
    binary: bool = false,
    location: ?[]const u8 = null,
};

/// Lambda function-URL (payload v2) response JSON.
fn respond(arena: std.mem.Allocator, r: Response) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.print("{{\"statusCode\":{d},\"headers\":{{\"Content-Type\":\"{s}\",\"Cache-Control\":\"{s}\",\"Access-Control-Allow-Origin\":\"*\"", .{ r.status, r.content_type, r.cache_control });
    if (r.location) |loc| try w.print(",\"Location\":\"{s}\"", .{loc});
    try w.writeAll("},\"isBase64Encoded\":");
    if (r.binary) {
        const enc = std.base64.standard.Encoder;
        const buf = try arena.alloc(u8, enc.calcSize(r.body.len));
        const b64 = enc.encode(buf, r.body);
        try w.print("true,\"body\":\"{s}\"}}", .{b64});
    } else {
        try w.writeAll("false,\"body\":\"");
        for (r.body) |ch| {
            switch (ch) {
                '"' => try w.writeAll("\\\""),
                '\\' => try w.writeAll("\\\\"),
                '\n' => try w.writeAll("\\n"),
                else => try w.writeByte(ch),
            }
        }
        try w.writeAll("\"}");
    }
    return aw.toOwnedSlice();
}

fn queryParam(event: std.json.Value, key: []const u8) ?[]const u8 {
    const q = event.object.get("queryStringParameters") orelse return null;
    if (q != .object) return null;
    const v = q.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn safeSegment(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == '.')) return false;
    }
    return true;
}

pub fn isHttpEvent(event: std.json.Value) bool {
    return event == .object and event.object.get("rawPath") != null;
}

/// Route a function-URL event. Never throws for client errors — they become
/// 4xx responses; only infrastructure failures propagate.
pub fn handleHttp(arena: std.mem.Allocator, event: std.json.Value) ![]const u8 {
    const path_v = event.object.get("rawPath") orelse return respond(arena, .{ .status = 400, .body = "missing path" });
    if (path_v != .string) return respond(arena, .{ .status = 400, .body = "bad path" });
    const path = path_v.string;
    const prefix = "/tiles/v1/";
    if (!std.mem.startsWith(u8, path, prefix)) return respond(arena, .{ .status = 404, .body = "not found", .cache_control = "public, max-age=60" });
    const rest = path[prefix.len..];

    // /tiles/v1/<product>/manifest.json  and  /tiles/v1/<product>/timerange
    if (std.mem.endsWith(u8, rest, "/manifest.json")) {
        const product = rest[0 .. rest.len - "/manifest.json".len];
        if (radcore.products.indexOf(product) == null) return respond(arena, .{ .status = 404, .body = "unknown product" });
        const text = (try manifestText(product)) orelse return respond(arena, .{ .status = 404, .body = "no manifest" });
        return respond(arena, .{ .status = 200, .content_type = "application/json", .cache_control = "public, max-age=15", .body = text });
    }
    if (std.mem.endsWith(u8, rest, "/timerange")) {
        const product = rest[0 .. rest.len - "/timerange".len];
        if (radcore.products.indexOf(product) == null) return respond(arena, .{ .status = 404, .body = "unknown product" });
        const text = (try manifestText(product)) orelse return respond(arena, .{ .status = 404, .body = "no manifest" });
        const m = try parseManifest(arena, text);
        var aw: std.Io.Writer.Allocating = .init(arena);
        try aw.writer.writeAll("{\"timestamps\":[");
        for (m.frames, 0..) |f, i| {
            if (i > 0) try aw.writer.writeAll(",");
            try aw.writer.print("\"{s}\"", .{f.time});
        }
        try aw.writer.writeAll("]}");
        return respond(arena, .{ .status = 200, .content_type = "application/json", .cache_control = "public, max-age=15", .body = try aw.toOwnedSlice() });
    }

    // <product…>/<stamp>/<z>/<x>/<y>.png — product may contain '/', so parse from the end
    var segs: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, rest, '/');
    while (it.next()) |s| try segs.append(arena, s);
    if (segs.items.len < 5) return respond(arena, .{ .status = 404, .body = "not found" });
    const n = segs.items.len;
    const ypng = segs.items[n - 1];
    if (!std.mem.endsWith(u8, ypng, ".png")) return respond(arena, .{ .status = 404, .body = "not found" });
    const z = std.fmt.parseInt(u32, segs.items[n - 3], 10) catch return respond(arena, .{ .status = 400, .body = "bad z" });
    const x = std.fmt.parseInt(u32, segs.items[n - 2], 10) catch return respond(arena, .{ .status = 400, .body = "bad x" });
    var y = std.fmt.parseInt(u32, ypng[0 .. ypng.len - 4], 10) catch return respond(arena, .{ .status = 400, .body = "bad y" });
    const st = segs.items[n - 4];
    const product = try std.mem.join(arena, "/", segs.items[0 .. n - 4]);
    if (radcore.products.indexOf(product) == null) return respond(arena, .{ .status = 404, .body = "unknown product", .cache_control = "public, max-age=60" });
    if (z > MAX_ZOOM) return respond(arena, .{ .status = 404, .body = "zoom out of range", .cache_control = "public, max-age=86400" });
    const nt: u64 = @as(u64, 1) << @intCast(z);
    if (x >= nt or y >= nt) return respond(arena, .{ .status = 400, .body = "tile out of range" });

    const tms = if (queryParam(event, "tms")) |v| (std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true")) else false;
    if (tms) y = @intCast(nt - 1 - y);
    var size: u32 = 256;
    if (queryParam(event, "size")) |v| {
        if (std.mem.eql(u8, v, "512")) size = 512 else if (!std.mem.eql(u8, v, "256")) return respond(arena, .{ .status = 400, .body = "size must be 256 or 512" });
    }
    var palette: i32 = 0;
    if (queryParam(event, "palette")) |v| palette = std.fmt.parseInt(i32, v, 10) catch 0;
    if (palette < 0 or palette > 1) palette = 0;

    if (std.mem.eql(u8, st, "latest")) {
        const newest = (try newestStamp(arena, product)) orelse return respond(arena, .{ .status = 404, .body = "no frames" });
        // keep the caller's query so tms/size/palette survive the redirect
        var loc: std.Io.Writer.Allocating = .init(arena);
        try loc.writer.print("{s}{s}/{s}/{d}/{d}/{s}", .{ prefix, product, newest, z, x, ypng });
        if (event.object.get("rawQueryString")) |q| {
            if (q == .string and q.string.len > 0) try loc.writer.print("?{s}", .{q.string});
        }
        return respond(arena, .{ .status = 302, .cache_control = "public, max-age=15", .location = try loc.toOwnedSlice() });
    }
    if (!safeSegment(st) or !stamp.validId(st)) return respond(arena, .{ .status = 400, .body = "bad stamp" });

    const rendered = (try render(arena, .{ .product = product, .stamp = st, .z = z, .x = x, .y = y, .size = size, .palette = palette })) orelse
        return respond(arena, .{ .status = 404, .body = "unknown stamp", .cache_control = "public, max-age=60" });
    return respond(arena, .{
        .status = 200,
        .content_type = "image/png",
        .cache_control = "public, max-age=31536000, immutable",
        .body = rendered.png,
        .binary = true,
    });
}

/// CLI: render one tile to a file (local dir or /vsis3 root).
pub fn renderToFile(alloc: std.mem.Allocator, req: Request, out_path: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const r = (try render(arena, req)) orelse return error.UnknownProductOrStamp;
    try gdal.vsiWrite(alloc, out_path, r.png);
    log.info("{s} {s} z{d}/{d}/{d}: {d} frames, {s}, {d} bytes -> {s}", .{ req.product, req.stamp, req.z, req.x, req.y, r.frames, if (r.empty) "empty" else "data", r.png.len, out_path });
}

const testing = std.testing;

test "tiles: path parsing rejects garbage, respond() builds valid v2 JSON" {
    const alloc = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bad = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"rawPath\":\"/tiles/v1/rads/20260901-205500/3/x/2.png\"}", .{});
    const r = try handleHttp(arena, bad);
    try testing.expect(std.mem.indexOf(u8, r, "\"statusCode\":400") != null);
    const nf = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"rawPath\":\"/nope\"}", .{});
    try testing.expect(std.mem.indexOf(u8, try handleHttp(arena, nf), "\"statusCode\":404") != null);
    const deep = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"rawPath\":\"/tiles/v1/rads/20260901-205500/15/0/0.png\"}", .{});
    try testing.expect(std.mem.indexOf(u8, try handleHttp(arena, deep), "\"statusCode\":404") != null);
    const png_resp = try respond(arena, .{ .status = 200, .content_type = "image/png", .body = "\x89PNG", .binary = true });
    try testing.expect(std.mem.indexOf(u8, png_resp, "\"isBase64Encoded\":true,\"body\":\"iVBORw==\"") != null);
    try testing.expect(isHttpEvent(bad) and !isHttpEvent(try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"Records\":[]}", .{})));
}

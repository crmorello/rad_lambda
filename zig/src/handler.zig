//! Event handling: env config, per-file processing (warp -> RAD v2 via
//! radcore -> optional gzip -> VSI write), S3/SNS/SQS event unwrapping,
//! region prefixes, 10-minute slice grid. Port of the Crystal handler.
//!
//! Records are routed per product by key extension (`kindForKey`): MRMS grib2
//! to the radar path, `.parquet` to the obs ingest. The two products run as
//! separate lambda functions off the same image, so routing here is what lets
//! one binary serve both.
const std = @import("std");
const radcore = @import("radcore");
const gdal = @import("gdal.zig");
const stamp = @import("stamp.zig");
const manifest = @import("manifest.zig");
const obs = @import("obs.zig");
const tiles = @import("tiles.zig");

/// Pixel density of the prod CONUS precip output (6373x4161 over the CONUS
/// mercator extent). Every region is warped to this so all RADs share one
/// pixel density regardless of extent.
pub const CONUS_PIXEL_SIZE_M: f64 = 1222.8;

/// Transport gzip at rest (lambda mode only; CLI writes plain files).
pub var gzip_output = false;

/// Precompute .flw flow sidecars at ingest (RAD_FLOW=0 opts out). Spec:
/// radcore/docs/flw-format.md — the flow ending at frame X.rad is X.flw.
pub var flow_enabled = true;
/// Flow estimate LOD for the .flw sidecar (see flowSidecar): node spacing is
/// BLOCK(32) * CONUS_PIXEL_SIZE_M * lod — lod 2 = ~78 km. A lod=1 (~39 km)
/// experiment was tried and REVERTED on 2026-09-14 for a DIFFERENT symptom
/// (crossfade/keyframing): measured on real CONUS pairs, lod 1 had both a
/// lower match rate (5.1-5.7% vs lod 2's 6.8-8.3%) and materially worse
/// frame-to-frame consistency of WHICH nodes matched (76-78% set overlap
/// vs 79-89% at lod 2) — the finer grid is noisier per block without a
/// compensating change to the diffusion-fill pass count.
///
/// lod=1 was re-adopted and DEPLOYED on 2026-09-16 for a different symptom
/// than the one that caused the earlier revert: visible warping/ghosting
/// where a 78 km node covers sharply non-uniform motion (rotation, a fast
/// cell embedded in slower stratiform rain) and the coarse vector gets
/// bilinearly smeared across the whole cell. The trade against the
/// keyframe/noise cost measured above has NOT been re-measured at lod 1 with
/// FLOW_SEARCH=20 — watch for the crossfade/keyframing symptom returning and
/// revert to 2 if it does.
pub const FLOW_LOD: u32 = 1;
/// Block-match search radius in texels, INDEPENDENT of FLOW_LOD (see
/// flow.zig's estimateSearch — a lambda-only knob; the client's synchronous
/// local-fallback estimate stays at the comptime SEARCH=8 to keep its
/// on-device cost down). Search scales the detectable-speed ceiling:
/// FLOW_SEARCH * CONUS_PIXEL_SIZE_M / 600s. At lod 2 with the old SEARCH=8
/// that ceiling was only ~32.6 m/s (echoes faster than that went unmatched
/// and diffusion-filled — the original "looks like a plain fade" report).
/// Measured: widening search alone (keeping lod 2) barely moves match rate
/// or frame-to-frame stability at all — this knob was never the source of
/// the lod-1 regression above, it's a clean, independent win. FLOW_SEARCH=20
/// at lod 2 gives ~81.5 m/s, comfortably above any real precip motion.
pub const FLOW_SEARCH: i32 = 20;

/// The pipeline's slice cadence: frames land on 10-minute boundaries, so the
/// previous frame of a pair is exactly one slice back.
pub const SLICE_INTERVAL_MS: i64 = 10 * std.time.ms_per_min;

/// RAD_RAD3 unset or anything but "0" → write RAD3; "0" → RAD2. One switch
/// for radar and obs.
pub fn rad3Enabled() bool {
    const v = getenv("RAD_RAD3") orelse return true;
    return !std.mem.eql(u8, v, "0");
}

/// libc getenv (std.posix.getenv is gone in 0.16; we link libc anyway).
pub fn getenv(key: [:0]const u8) ?[]const u8 {
    const v = std.c.getenv(key.ptr) orelse return null;
    return std.mem.span(v);
}

pub fn resolution() f64 {
    const v = getenv("RAD_RESOLUTION") orelse return CONUS_PIXEL_SIZE_M;
    return std.fmt.parseFloat(f64, v) catch CONUS_PIXEL_SIZE_M;
}

/// e.g. "/vsis3/my-bucket/rads" or a local directory
pub fn outputDir() ![]const u8 {
    return getenv("RAD_OUTPUT") orelse error.MissingRadOutput;
}

/// Manifest timeline window in ms (RAD_MANIFEST_HOURS, default 3; 0 or
/// negative = unwindowed). Older RADs stay in the bucket, fetchable by URL.
pub fn manifestWindowMs() i64 {
    const hours: f64 = blk: {
        const v = getenv("RAD_MANIFEST_HOURS") orelse break :blk 3.0;
        break :blk std.fmt.parseFloat(f64, v) catch 3.0;
    };
    if (hours <= 0) return 0;
    return @intFromFloat(hours * std.time.ms_per_hour);
}

/// First key path segment -> client region id prefix. CONUS is the primary
/// product and stays unprefixed; everything else is lowercased + "_".
pub fn regionPrefix(alloc: std.mem.Allocator, key: []const u8) ![]const u8 {
    const end = std.mem.indexOfScalar(u8, key, '/') orelse key.len;
    const region = try std.ascii.allocLowerString(alloc, key[0..end]);
    if (std.mem.eql(u8, region, "conus")) {
        alloc.free(region);
        return try alloc.dupe(u8, "");
    }
    defer alloc.free(region);
    return try std.fmt.allocPrint(alloc, "{s}_", .{region});
}

/// Serving path of the output dir for manifest URLs: explicit RAD_URL_PREFIX,
/// else derived from RAD_OUTPUT ("/vsis3/bucket/rads" -> "/rads"; local -> "").
pub fn urlPrefix(alloc: std.mem.Allocator) ![]const u8 {
    if (getenv("RAD_URL_PREFIX")) |explicit| {
        return try alloc.dupe(u8, std.mem.trimEnd(u8, explicit, "/"));
    }
    const out = std.mem.trimEnd(u8, try outputDir(), "/");
    if (std.mem.startsWith(u8, out, "/vsis3/")) {
        const rest = out["/vsis3/".len..];
        if (std.mem.indexOfScalar(u8, rest, '/')) |idx| {
            return try std.fmt.allocPrint(alloc, "/{s}", .{rest[idx + 1 ..]});
        }
    }
    return try alloc.dupe(u8, "");
}

const Encoded = struct { rad: []u8, path: []const u8 };

/// Encode a warped band AT `s` and write it to `{out_dir}/{id_prefix}{s}.rad`.
/// Split out of processFile because the 5-minute tile slots need the same
/// encode+write under a DIFFERENT stamp than the source grib carries.
/// Caller frees both fields.
fn encodeAndWrite(alloc: std.mem.Allocator, warped: gdal.Warped, s: stamp.Stamp, out_dir: []const u8, id_prefix: []const u8) !Encoded {
    // RAD3 (paged best-of stream) for radar too — CONUS 0.79 → 0.55 MB,
    // Alaska 0.31 → 0.13 MB, and page-addressable decode in the clients.
    // RAD_RAD3=0 keeps RAD2 (every client decodes both).
    const rad = if (rad3Enabled())
        try radcore.rad3.writeRadV3(alloc, s.ms(), warped.geo_tran, warped.max_x, warped.max_y, warped.no_data, warped.band)
    else
        try radcore.writeRadV2(alloc, s.ms(), warped.geo_tran, warped.max_x, warped.max_y, warped.no_data, warped.band);
    errdefer alloc.free(rad);
    std.log.info("{s}{s}: {d} bytes ({s})", .{ id_prefix, s.slice(), rad.len, rad[0..4] });
    const body = if (gzip_output) try manifest.gzipBytes(alloc, rad) else rad;
    defer if (gzip_output) alloc.free(body);

    const out_path = try std.fmt.allocPrint(alloc, "{s}/{s}{s}.rad", .{
        std.mem.trimEnd(u8, out_dir, "/"), id_prefix, s.slice(),
    });
    errdefer alloc.free(out_path);
    try gdal.vsiWrite(alloc, out_path, body);
    return .{ .rad = rad, .path = out_path };
}

/// One raster in, one RAD out. Returns the written path (caller frees).
pub fn processFile(alloc: std.mem.Allocator, input: []const u8, out_dir: []const u8, res: f64, id_prefix: []const u8) ![]const u8 {
    const s = stamp.fromFilename(std.fs.path.basename(input)) orelse return error.NoTimestampInFilename;

    const warped = try gdal.warpBand(alloc, input, res);
    defer alloc.free(warped.band);

    const w = try encodeAndWrite(alloc, warped, s, out_dir, id_prefix);
    defer alloc.free(w.rad);

    // Best-effort flow sidecar for the pair ending at this frame — never
    // fails the ingest (flow is a derivation, regenerable at any time).
    if (flow_enabled) {
        flowSidecar(alloc, out_dir, id_prefix, s, w.rad) catch |err| {
            std.log.warn("flow sidecar skipped for {s}{s}: {s}", .{ id_prefix, s.slice(), @errorName(err) });
        };
    }
    return w.path;
}

/// Same warp, written under `target` instead of the source grib's own stamp —
/// the 5-minute tile slots, sourced from the :04 frame (or :06 as a fallback).
///
/// No flow sidecar: tiles never read .flw, and flowSidecar looks back a
/// hard-coded SLICE_INTERVAL_MS (10 min), which is wrong for this series.
/// Returns null when `if_absent` and the slot is already filled — that is how
/// the :06 fallback yields to a :04 that already landed, without tracking which
/// minute produced each slot.
fn processRelabelled(alloc: std.mem.Allocator, input: []const u8, out_dir: []const u8, res: f64, id_prefix: []const u8, target: stamp.Stamp, if_absent: bool) !?[]const u8 {
    if (if_absent) {
        const name = try std.fmt.allocPrint(alloc, "{s}{s}.rad", .{ id_prefix, target.slice() });
        defer alloc.free(name);
        if (gdal.dirHas(alloc, std.mem.trimEnd(u8, out_dir, "/"), name)) {
            std.log.info("5-min slot {s}{s} already filled; :06 yields", .{ id_prefix, target.slice() });
            return null;
        }
    }
    const warped = try gdal.warpBand(alloc, input, res);
    defer alloc.free(warped.band);
    const w = try encodeAndWrite(alloc, warped, target, out_dir, id_prefix);
    alloc.free(w.rad);
    return w.path;
}

/// Which slot of the tile timeline an MRMS stamp feeds.
///
/// MRMS publishes every 2 minutes; the tile timeline wants :00,:05,:10,:15,…
/// The :00/:10 frames ARE the 10-minute series and are written once to rads/.
/// The in-between slots come from :04 (1 min early) or :06 as a fallback when
/// :04 never landed. :02 is deliberately unusable: it arrives BEFORE :04, so
/// honouring the preference would need a delayed write or per-slot source
/// tracking, and 3 minutes of drift is too much to relabel as :05.
/// Where the 5-minute in-between frames live: a subdirectory of the radar
/// output, so it inherits the bucket lifecycle rule on rads/ and — because
/// gdal.readDirEntries lists one level only — cannot leak into the 10-minute
/// manifest built by listing rads/.
fn fiveMinDir(alloc: std.mem.Allocator, out_dir: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}/5min", .{std.mem.trimEnd(u8, out_dir, "/")});
}

pub const Slot = enum { ten_minute, fill, fill_fallback, none };

pub fn slotFor(s: *const stamp.Stamp) Slot {
    if (s.text[13] != '0' or s.text[14] != '0') return .none; // seconds must be :00
    return switch (s.text[12]) { // units digit of the minute
        '0' => .ten_minute,
        '4' => .fill,
        '6' => .fill_fallback,
        else => .none,
    };
}

/// Write "{prefix}{stamp}.flw" for the pair (stamp - 10 min) -> stamp: read
/// the previous slice's RAD back from the output dir, estimate flow via
/// radcore, encode per spec (confidence plane on, vec_scale 2 m/count,
/// lod FLOW_LOD). Missing previous frame = gap = write nothing; a 404 on the
/// sidecar is the client's dissolve signal.
fn flowSidecar(alloc: std.mem.Allocator, out_dir: []const u8, id_prefix: []const u8, s: stamp.Stamp, next_rad: []const u8) !void {
    const prev_s = stamp.fromMs(s.ms() - SLICE_INTERVAL_MS) orelse return;
    const prev_path = try std.fmt.allocPrint(alloc, "{s}/{s}{s}.rad", .{
        std.mem.trimEnd(u8, out_dir, "/"), id_prefix, prev_s.slice(),
    });
    defer alloc.free(prev_path);
    // Warm containers cache vsicurl directory listings AND misses — a
    // listing taken before the previous frame existed makes this read fail
    // without a network request (the exact trap clearVsiCache documents).
    gdal.clearVsiCache(alloc, prev_path);
    const prev_raw = (try gdal.vsiRead(alloc, prev_path)) orelse {
        // Gap policy: no previous frame -> no sidecar. Logged with GDAL's
        // last error so a genuine gap (silent 404) and an access/transport
        // failure are distinguishable in CloudWatch.
        const gerr = std.mem.span(gdal.c.CPLGetLastErrorMsg());
        std.log.info("flow sidecar {s}{s}.flw: skipped (no previous frame at {s}{s}{s})", .{
            id_prefix,                            s.slice(), prev_path,
            if (gerr.len > 0) "; gdal: " else "", gerr,
        });
        return;
    };
    const prev_rad = try manifest.gunzipIfNeeded(alloc, prev_raw); // owns prev_raw
    defer alloc.free(prev_rad);

    const recOf = struct {
        fn rec(bytes: []const u8, h: radcore.store.RadHeader) radcore.ZCRadFile {
            return .{
                .geo_tran = h.geo_tran,
                .max_x = h.max_x,
                .max_y = h.max_y,
                .original_size = h.original_size,
                .compressed = bytes.ptr + h.stream_off,
                .compressed_len = h.stream_len,
                .rle_version = h.rle_version,
            };
        }
    }.rec;
    const ph = radcore.store.parseRadHeader(prev_rad) orelse return error.BadPreviousRad;
    const nh = radcore.store.parseRadHeader(next_rad) orelse return error.BadNextRad;

    // FLOW_LOD (grid density) and FLOW_SEARCH (speed ceiling) are decoupled —
    // see their doc comments above for why. This is the lambda's async,
    // one-time ingest cost; the client's local-fallback estimate stays cheap
    // (comptime SEARCH=8) since it runs synchronously on-device.
    const flw = try radcore.flow_file.flowFileForPair(
        alloc,
        recOf(prev_rad, ph),
        ph.time,
        recOf(next_rad, nh),
        nh.time,
        FLOW_LOD,
        radcore.flow_file.DEFAULT_VEC_SCALE,
        FLOW_SEARCH,
    );
    defer alloc.free(flw);
    const flw_body = if (gzip_output) try manifest.gzipBytes(alloc, flw) else flw;
    defer if (gzip_output) alloc.free(flw_body);
    const flw_path = try std.fmt.allocPrint(alloc, "{s}/{s}{s}.flw", .{
        std.mem.trimEnd(u8, out_dir, "/"), id_prefix, s.slice(),
    });
    defer alloc.free(flw_path);
    try gdal.vsiWrite(alloc, flw_path, flw_body);
    std.log.info("flow sidecar {s}{s}.flw: {d} B raw, {d} B at rest", .{
        id_prefix, s.slice(), flw.len, flw_body.len,
    });
}

/// Local dev/QA tool: regenerate one "{next_id}.flw" from two EXISTING .rad
/// files already on disk (no GRIB2/S3 needed) — same estimator, same
/// FLOW_LOD/FLOW_SEARCH/vec_scale as production `flowSidecar`, so a fixture
/// pair run through this produces exactly what the lambda would write today.
/// For visually checking a tuning change before deploying: point raydare's
/// local dev server (`server -dir <dir>`) at `dir` and it'll pick up the
/// generated .flw the same way it'd pick one up from S3.
pub fn flowFileFromLocalPair(alloc: std.mem.Allocator, dir: []const u8, prev_id: []const u8, next_id: []const u8, out_dir: []const u8) !void {
    const prev_path = try std.fmt.allocPrint(alloc, "{s}/{s}.rad", .{ std.mem.trimEnd(u8, dir, "/"), prev_id });
    defer alloc.free(prev_path);
    const next_path = try std.fmt.allocPrint(alloc, "{s}/{s}.rad", .{ std.mem.trimEnd(u8, dir, "/"), next_id });
    defer alloc.free(next_path);

    const prev_raw = try gdal.vsiRead(alloc, prev_path) orelse return error.PrevRadNotFound;
    const prev_rad = try manifest.gunzipIfNeeded(alloc, prev_raw); // owns prev_raw
    defer alloc.free(prev_rad);
    const next_raw = try gdal.vsiRead(alloc, next_path) orelse return error.NextRadNotFound;
    const next_rad = try manifest.gunzipIfNeeded(alloc, next_raw); // owns next_raw
    defer alloc.free(next_rad);

    const recOf = struct {
        fn rec(bytes: []const u8, h: radcore.store.RadHeader) radcore.ZCRadFile {
            return .{
                .geo_tran = h.geo_tran,
                .max_x = h.max_x,
                .max_y = h.max_y,
                .original_size = h.original_size,
                .compressed = bytes.ptr + h.stream_off,
                .compressed_len = h.stream_len,
                .rle_version = h.rle_version,
            };
        }
    }.rec;
    const ph = radcore.store.parseRadHeader(prev_rad) orelse return error.BadPreviousRad;
    const nh = radcore.store.parseRadHeader(next_rad) orelse return error.BadNextRad;

    const flw = try radcore.flow_file.flowFileForPair(
        alloc,
        recOf(prev_rad, ph),
        ph.time,
        recOf(next_rad, nh),
        nh.time,
        FLOW_LOD,
        radcore.flow_file.DEFAULT_VEC_SCALE,
        FLOW_SEARCH,
    );
    defer alloc.free(flw);
    const flw_path = try std.fmt.allocPrint(alloc, "{s}/{s}.flw", .{ std.mem.trimEnd(u8, out_dir, "/"), next_id });
    defer alloc.free(flw_path);
    try gdal.vsiWrite(alloc, flw_path, flw);
    std.log.info("flow (local pair) {s}.flw: {d} B, lod {d} search {d}", .{ next_id, flw.len, FLOW_LOD, FLOW_SEARCH });
}

/// application/x-www-form-urlencoded decode (S3 event keys): '+' -> space,
/// then percent-decode.
fn decodeKey(alloc: std.mem.Allocator, key: []const u8) ![]u8 {
    const buf = try alloc.dupe(u8, key);
    for (buf) |*ch| {
        if (ch.* == '+') ch.* = ' ';
    }
    var read: usize = 0;
    var write: usize = 0;
    while (read < buf.len) : (write += 1) {
        if (buf[read] == '%' and read + 2 < buf.len) {
            const hi = std.fmt.charToDigit(buf[read + 1], 16) catch {
                buf[write] = buf[read];
                read += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(buf[read + 2], 16) catch {
                buf[write] = buf[read];
                read += 1;
                continue;
            };
            buf[write] = hi * 16 + lo;
            read += 3;
        } else {
            buf[write] = buf[read];
            read += 1;
        }
    }
    return buf[0..write];
}

/// Normalize any trigger shape to raw S3 records. The production chain is
/// NOAA SNS -> our SQS -> event-source mapping, which nests THREE layers
/// (SQS record body = SNS envelope JSON, whose Message = the S3 event);
/// direct SNS->Lambda and raw S3 events also work.
fn collectS3Records(arena: std.mem.Allocator, event: std.json.Value, out: *std.ArrayList(std.json.Value)) !void {
    const obj = switch (event) {
        .object => |o| o,
        else => return,
    };
    const records = obj.get("Records") orelse return;
    const arr = switch (records) {
        .array => |a| a,
        else => return,
    };
    for (arr.items) |record| {
        const rec_obj = switch (record) {
            .object => |o| o,
            else => continue,
        };
        if (rec_obj.get("body")) |body| { // SQS envelope
            const inner = std.json.parseFromSliceLeaky(std.json.Value, arena, body.string, .{}) catch continue;
            if (inner == .object) {
                if (inner.object.get("Message")) |message| { // SNS envelope inside
                    const msg = std.json.parseFromSliceLeaky(std.json.Value, arena, message.string, .{}) catch continue;
                    try collectS3Records(arena, msg, out);
                    continue;
                }
            }
            try collectS3Records(arena, inner, out);
        } else if (rec_obj.get("Sns")) |sns| { // direct SNS -> Lambda
            const msg = std.json.parseFromSliceLeaky(std.json.Value, arena, sns.object.get("Message").?.string, .{}) catch continue;
            try collectS3Records(arena, msg, out);
        } else if (rec_obj.get("s3") != null) {
            try out.append(arena, record);
        }
    }
}

/// Which producer a key routes to. Deliberately keyed on the EXTENSION and not
/// on the bucket: the bucket arrives in the S3 event, and the obs source is a
/// third-party bucket behind CloudFront, so hard-coding it here would just be
/// deploy config leaking into the binary.
pub const InputKind = enum { radar, obs };

/// Optional comma-separated allow-list of key prefixes (RAD_KEY_PREFIXES).
/// Unset = accept any key, which is the radar behaviour (its trigger is an SNS
/// filter policy scoped to the SeamlessHSR paths already).
///
/// Set it when the TRIGGER is broader than the product's own prefix. The obs
/// source is `ft.weatherflow.com`, a general-purpose bucket whose producer
/// invokes this function on every write it makes, so that function sets
/// `gcc/output/`. Without it, kindForKey routes on extension alone and a
/// stray .parquet anywhere in the bucket would be ingested as an obs issuance.
fn keyAllowed(key: []const u8) bool {
    return prefixAllowed(key, getenv("RAD_KEY_PREFIXES"));
}

/// The rule itself, taking the list explicitly so it is testable without
/// mutating the process environment. `null` list = accept everything.
fn prefixAllowed(key: []const u8, list: ?[]const u8) bool {
    const l = list orelse return true;
    var it = std.mem.splitScalar(u8, l, ',');
    while (it.next()) |raw| {
        const p = std.mem.trim(u8, raw, " ");
        if (p.len > 0 and std.mem.startsWith(u8, key, p)) return true;
    }
    return false;
}

pub fn kindForKey(key: []const u8) ?InputKind {
    // Same extension set main.zig walks in CLI directory mode.
    if (std.mem.endsWith(u8, key, ".grib2") or
        std.mem.endsWith(u8, key, ".grb2") or
        std.mem.endsWith(u8, key, ".grib2.gz")) return .radar;
    if (std.mem.endsWith(u8, key, ".parquet")) return .obs;
    return null;
}

/// obs.ingest on the C allocator, NOT the invocation arena. ingest allocates a
/// ~16 MB band plus a ~13 MB RAD per product and frees each before the next,
/// but ArenaAllocator.free is a no-op (it can only shrink the most recent
/// allocation), so on the arena those 13 rounds would pile up to ~500 MB
/// instead of being reused. Radar never exposed this: it allocates one band per
/// record. Paths are copied onto the arena for the response and the originals
/// released here.
fn ingestObs(arena: std.mem.Allocator, input: []const u8) ![][]const u8 {
    const alloc = std.heap.c_allocator;
    const written = try obs.ingest(alloc, input, try outputDir(), resolution(), gzip_output, manifestWindowMs());
    defer {
        for (written) |w| alloc.free(w.path);
        alloc.free(written);
    }
    const paths = try arena.alloc([]const u8, written.len);
    for (written, 0..) |w, i| paths[i] = try arena.dupe(u8, w.path);
    return paths;
}

/// Trigger event -> RAD per routed record + manifest rebuild. Returns the
/// JSON response body. All allocation on `arena` (freed per invocation),
/// except obs.ingest — see ingestObs.
pub fn handleEvent(arena: std.mem.Allocator, event_json: []const u8) ![]const u8 {
    const event = try std.json.parseFromSliceLeaky(std.json.Value, arena, event_json, .{});
    // Function-URL requests (the tile endpoint) arrive as HTTP events, not
    // S3 records: route them and return the HTTP response JSON.
    if (tiles.isHttpEvent(event)) return tiles.handleHttp(arena, event);

    var records: std.ArrayList(std.json.Value) = .empty;
    try collectS3Records(arena, event, &records);

    var outputs: std.ArrayList([]const u8) = .empty;
    var skipped: usize = 0;
    var radar_written = false;
    var fill_written = false;
    for (records.items) |record| {
        const s3 = record.object.get("s3").?.object;
        const bucket = s3.get("bucket").?.object.get("name").?.string;
        const key = try decodeKey(arena, s3.get("object").?.object.get("key").?.string);
        const name = std.fs.path.basename(key);

        // An unroutable key is SKIPPED, never an error. Failing the record
        // fails the whole SQS batch and eventually DLQs it, and one stray
        // object in a watched prefix should not do that. A real upstream
        // rename still surfaces: nothing gets written, so the freshness alarm
        // (deploy/05-alarms.sh) fires on its own.
        // Cheapest gate first: an over-broad trigger (see keyAllowed) means most
        // records are none of our business, and this rejects them before any
        // extension match or GDAL work.
        if (!keyAllowed(key)) {
            std.log.warn("skipping {s}: outside RAD_KEY_PREFIXES", .{key});
            skipped += 1;
            continue;
        }
        const kind = kindForKey(key) orelse {
            std.log.warn("skipping {s}: no producer for this key", .{key});
            skipped += 1;
            continue;
        };
        const input = try std.fmt.allocPrint(arena, "/vsis3/{s}/{s}", .{ bucket, key });

        switch (kind) {
            .radar => {
                const s = stamp.fromFilename(name) orelse {
                    std.log.warn("skipping {s}: no timestamp in filename", .{key});
                    skipped += 1;
                    continue;
                };
                const slot = slotFor(&s);
                if (slot == .none) {
                    skipped += 1;
                    continue;
                }
                const prefix = try regionPrefix(arena, key);
                const out = try outputDir();
                if (slot == .ten_minute) {
                    // Unchanged: ONE write to rads/, and the 10-minute manifest
                    // that .rad clients read stays exactly as it was.
                    try outputs.append(arena, try processFile(arena, input, out, resolution(), prefix));
                    radar_written = true;
                } else {
                    // :04 -> +1 min, :06 -> -1 min; both land on the :05 slot.
                    const delta: i64 = if (slot == .fill) std.time.ms_per_min else -std.time.ms_per_min;
                    const target = stamp.fromMs(s.ms() + delta) orelse {
                        skipped += 1;
                        continue;
                    };
                    const five = try fiveMinDir(arena, out);
                    if (try processRelabelled(arena, input, five, resolution(), prefix, target, slot == .fill_fallback)) |path| {
                        try outputs.append(arena, path);
                        fill_written = true;
                    } else {
                        skipped += 1;
                    }
                }
            },
            // No slice-grid gate (obs issuances sit off the 10-minute lattice
            // — the epoch sample is 20:55:00) and no region prefix (H3 is
            // global; obs namespaces by variable directory instead). ingest
            // writes its own 13 per-variable manifests.
            .obs => {
                if (obs.stampFromName(name) == null) {
                    std.log.warn("skipping {s}: no timestamp in filename", .{key});
                    skipped += 1;
                    continue;
                }
                for (try ingestObs(arena, input)) |path| try outputs.append(arena, path);
            },
        }
    }

    // Gated on radar records, NOT on outputs.len: an obs-only invocation would
    // otherwise rebuild a "reflectivity" manifest by listing RAD_OUTPUT, which
    // for the obs function is the bucket root.
    if (radar_written) {
        const prefix = try urlPrefix(arena);
        try manifest.rebuild(arena, try outputDir(), prefix, "reflectivity", gzip_output, manifestWindowMs());
    }
    // The TILE timeline: one manifest interleaving the 10-minute frames in
    // rads/ with the 5-minute in-betweens in rads/5min/, neither copied.
    if (radar_written or fill_written) {
        const out = std.mem.trimEnd(u8, try outputDir(), "/");
        const up = try urlPrefix(arena);
        const five = try fiveMinDir(arena, out);
        const five_up = try std.fmt.allocPrint(arena, "{s}/5min", .{up});
        const out_path = try std.fmt.allocPrint(arena, "{s}/manifest.json", .{five});
        try manifest.rebuildFrom(arena, out_path, &.{
            .{ .dir = out, .url_prefix = up },
            .{ .dir = five, .url_prefix = five_up },
        }, "reflectivity", gzip_output, manifestWindowMs());
    }

    var response: std.Io.Writer.Allocating = .init(arena);
    const w = &response.writer;
    try w.writeAll("{\"processed\":[");
    for (outputs.items, 0..) |path, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("\"{s}\"", .{path});
    }
    try w.print("],\"skipped\":{d}}}", .{skipped});
    return response.toOwnedSlice();
}

test "region prefix + url prefix derivation" {
    const alloc = std.testing.allocator;
    const conus = try regionPrefix(alloc, "CONUS/MRMS_x.grib2.gz");
    defer alloc.free(conus);
    try std.testing.expectEqualStrings("", conus);
    const alaska = try regionPrefix(alloc, "ALASKA/MRMS_x.grib2.gz");
    defer alloc.free(alaska);
    try std.testing.expectEqualStrings("alaska_", alaska);
}

test "s3 record unwrapping: raw, SNS, SQS-wrapped-SNS" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const raw =
        \\{"Records":[{"s3":{"bucket":{"name":"b"},"object":{"key":"CONUS/x_20260714-174000.grib2.gz"}}}]}
    ;
    const event = try std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{});
    var records: std.ArrayList(std.json.Value) = .empty;
    try collectS3Records(arena, event, &records);
    try std.testing.expectEqual(@as(usize, 1), records.items.len);

    // SQS body containing an SNS envelope containing the raw event
    const sqs = try std.fmt.allocPrint(arena, "{{\"Records\":[{{\"body\":{f}}}]}}", .{
        std.json.fmt(try std.fmt.allocPrint(arena, "{{\"Message\":{f}}}", .{std.json.fmt(raw, .{})}), .{}),
    });
    const sqs_event = try std.json.parseFromSliceLeaky(std.json.Value, arena, sqs, .{});
    var sqs_records: std.ArrayList(std.json.Value) = .empty;
    try collectS3Records(arena, sqs_event, &sqs_records);
    try std.testing.expectEqual(@as(usize, 1), sqs_records.items.len);
}

test "kindForKey: routing by extension" {
    try std.testing.expectEqual(InputKind.radar, kindForKey("CONUS/MRMS_SeamlessHSR_00.00_20260712-005000.grib2.gz").?);
    try std.testing.expectEqual(InputKind.radar, kindForKey("a/b_20260712-005000.grib2").?);
    try std.testing.expectEqual(InputKind.radar, kindForKey("a/b_20260712-005000.grb2").?);
    try std.testing.expectEqual(InputKind.obs, kindForKey("gcc/output/1788296100_slim.parquet").?);
    // Anything we have no producer for routes nowhere (and is skipped, not an error).
    try std.testing.expect(kindForKey("gcc/output/_SUCCESS") == null);
    try std.testing.expect(kindForKey("gcc/output/README.txt") == null);
    try std.testing.expect(kindForKey("no-extension") == null);
    try std.testing.expect(kindForKey("") == null);
}

test "handleEvent: unroutable and stampless keys skip instead of failing the batch" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // None of these reach outputDir(), so no RAD_OUTPUT is needed here.
    const cases = [_][]const u8{
        // No producer for the key: a stray object in a watched prefix.
        \\{"Records":[{"s3":{"bucket":{"name":"b"},"object":{"key":"gcc/output/_SUCCESS"}}}]}
        ,
        // Grib with no stamp: used to return error.NoTimestampInFilename and
        // fail the whole SQS batch into the DLQ.
        \\{"Records":[{"s3":{"bucket":{"name":"b"},"object":{"key":"CONUS/latest.grib2.gz"}}}]}
        ,
        // Parquet with no stamp: obs.stampFromName wants a 10-digit epoch or
        // an embedded YYYYMMDD-HHMMSS.
        \\{"Records":[{"s3":{"bucket":{"name":"b"},"object":{"key":"gcc/output/slim.parquet"}}}]}
        ,
    };
    for (cases) |event| {
        try std.testing.expectEqualStrings(
            "{\"processed\":[],\"skipped\":1}",
            try handleEvent(arena, event),
        );
    }
}

test "prefixAllowed: RAD_KEY_PREFIXES narrows an over-broad trigger" {
    // Unset = accept everything. That is the radar case: its SNS filter policy
    // already scopes the trigger to the SeamlessHSR paths.
    try std.testing.expect(prefixAllowed("anything/at/all.parquet", null));
    try std.testing.expect(prefixAllowed("", null));

    // The obs case: the producer invokes us for every write to
    // ft.weatherflow.com, so only gcc/output/ is ours.
    const one = "gcc/output/";
    try std.testing.expect(prefixAllowed("gcc/output/1788296100_slim.parquet", one));
    try std.testing.expect(!prefixAllowed("gcc/1788296100_slim.parquet", one));
    try std.testing.expect(!prefixAllowed("other/1788296100_slim.parquet", one));
    // A stray parquet elsewhere in the bucket must NOT become an obs issuance:
    // kindForKey matches on extension alone, so this gate is what stops it.
    try std.testing.expect(!prefixAllowed("uploads/random.parquet", one));

    // Comma list with padding, written the way RAD_UNSIGNED_BUCKETS is.
    const two = "gcc/output/, alt/feed/";
    try std.testing.expect(prefixAllowed("gcc/output/x.parquet", two));
    try std.testing.expect(prefixAllowed("alt/feed/x.parquet", two));
    try std.testing.expect(!prefixAllowed("nope/x.parquet", two));

    // An empty or whitespace-only value must not accidentally allow everything.
    try std.testing.expect(!prefixAllowed("gcc/output/x.parquet", ""));
    try std.testing.expect(!prefixAllowed("gcc/output/x.parquet", " , "));
}

test "slotFor: which MRMS minutes feed the tile timeline" {
    const mk = struct {
        fn s(text: *const [15]u8) stamp.Stamp {
            var out: stamp.Stamp = undefined;
            @memcpy(&out.text, text);
            return out;
        }
    }.s;
    // :00 and :10 ARE the 10-minute series — written once to rads/.
    try std.testing.expectEqual(Slot.ten_minute, slotFor(&mk("20260712-010000")));
    try std.testing.expectEqual(Slot.ten_minute, slotFor(&mk("20260712-011000")));
    try std.testing.expectEqual(Slot.ten_minute, slotFor(&mk("20260712-012000")));
    // :04 is the preferred source for the in-between slot, :06 the fallback.
    try std.testing.expectEqual(Slot.fill, slotFor(&mk("20260712-010400")));
    try std.testing.expectEqual(Slot.fill, slotFor(&mk("20260712-011400")));
    try std.testing.expectEqual(Slot.fill_fallback, slotFor(&mk("20260712-010600")));
    try std.testing.expectEqual(Slot.fill_fallback, slotFor(&mk("20260712-012600")));
    // :02 and :08 are dropped — see the doc comment on Slot.
    try std.testing.expectEqual(Slot.none, slotFor(&mk("20260712-010200")));
    try std.testing.expectEqual(Slot.none, slotFor(&mk("20260712-010800")));
    // Odd minutes never appear in MRMS, but must not classify as anything.
    try std.testing.expectEqual(Slot.none, slotFor(&mk("20260712-010500")));
    // Seconds must be :00 — a sub-minute stamp is not a slice.
    try std.testing.expectEqual(Slot.none, slotFor(&mk("20260712-010030")));
    try std.testing.expectEqual(Slot.none, slotFor(&mk("20260712-010401")));
}

test "5-minute relabel: :04 and :06 both land on the same :05 slot" {
    const mk = struct {
        fn s(text: *const [15]u8) stamp.Stamp {
            var out: stamp.Stamp = undefined;
            @memcpy(&out.text, text);
            return out;
        }
    }.s;
    const four = mk("20260712-010400");
    const six = mk("20260712-010600");
    const from_four = stamp.fromMs(four.ms() + std.time.ms_per_min).?;
    const from_six = stamp.fromMs(six.ms() - std.time.ms_per_min).?;
    try std.testing.expectEqualStrings("20260712-010500", from_four.slice());
    try std.testing.expectEqualStrings("20260712-010500", from_six.slice());

    // Hour and day rollover, since the relabel is plain ms arithmetic.
    try std.testing.expectEqualStrings(
        "20260712-020500",
        stamp.fromMs(mk("20260712-020400").ms() + std.time.ms_per_min).?.slice(),
    );
    try std.testing.expectEqualStrings(
        "20260713-000500",
        stamp.fromMs(mk("20260713-000400").ms() + std.time.ms_per_min).?.slice(),
    );
    // A relabelled id still passes the manifest's id filter, region prefix and all.
    try std.testing.expect(stamp.validId("20260712-010500"));
    try std.testing.expect(stamp.validId("alaska_20260712-010500"));
}

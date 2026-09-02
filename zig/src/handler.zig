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

/// Pixel density of the prod CONUS precip output (6373x4161 over the CONUS
/// mercator extent). Every region is warped to this so all RADs share one
/// pixel density regardless of extent.
pub const CONUS_PIXEL_SIZE_M: f64 = 1222.8;

/// Transport gzip at rest (lambda mode only; CLI writes plain files).
pub var gzip_output = false;

/// Precompute .flw flow sidecars at ingest (RAD_FLOW=0 opts out). Spec:
/// radcore/docs/flw-format.md — the flow ending at frame X.rad is X.flw.
pub var flow_enabled = true;
/// Flow estimate LOD for the .flw sidecar (see flowSidecar).
pub const FLOW_LOD: u32 = 2;

/// The pipeline's slice cadence: frames land on 10-minute boundaries, so the
/// previous frame of a pair is exactly one slice back.
pub const SLICE_INTERVAL_MS: i64 = 10 * std.time.ms_per_min;

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

/// One raster in, one RAD out. Returns the written path (caller frees).
pub fn processFile(alloc: std.mem.Allocator, input: []const u8, out_dir: []const u8, res: f64, id_prefix: []const u8) ![]const u8 {
    const s = stamp.fromFilename(std.fs.path.basename(input)) orelse return error.NoTimestampInFilename;

    const warped = try gdal.warpBand(alloc, input, res);
    defer alloc.free(warped.band);

    const rad = try radcore.writeRadV2(alloc, s.ms(), warped.geo_tran, warped.max_x, warped.max_y, warped.no_data, warped.band);
    defer alloc.free(rad);
    const body = if (gzip_output) try manifest.gzipBytes(alloc, rad) else rad;
    defer if (gzip_output) alloc.free(body);

    const out_path = try std.fmt.allocPrint(alloc, "{s}/{s}{s}.rad", .{
        std.mem.trimEnd(u8, out_dir, "/"), id_prefix, s.slice(),
    });
    errdefer alloc.free(out_path);
    try gdal.vsiWrite(alloc, out_path, body);

    // Best-effort flow sidecar for the pair ending at this frame — never
    // fails the ingest (flow is a derivation, regenerable at any time).
    if (flow_enabled) {
        flowSidecar(alloc, out_dir, id_prefix, s, rad) catch |err| {
            std.log.warn("flow sidecar skipped for {s}{s}: {s}", .{ id_prefix, s.slice(), @errorName(err) });
        };
    }
    return out_path;
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

    // lod 2, like the client's own estimate: the ±8-texel search window is a
    // speed ceiling (16.3 m/s at lod 1 over a 10-min gap — measured: every
    // echo above it went unmatched and diffusion-filled, mean speeds ~30 %
    // low). lod 2 doubles the ceiling to 32.6 m/s at a 78 km node grid.
    const flw = try radcore.flow_file.flowFileForPair(
        alloc,
        recOf(prev_rad, ph),
        ph.time,
        recOf(next_rad, nh),
        nh.time,
        FLOW_LOD,
        radcore.flow_file.DEFAULT_VEC_SCALE,
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

    var records: std.ArrayList(std.json.Value) = .empty;
    try collectS3Records(arena, event, &records);

    var outputs: std.ArrayList([]const u8) = .empty;
    var skipped: usize = 0;
    var radar_written = false;
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
                if (!s.onSliceGrid()) {
                    skipped += 1;
                    continue;
                }
                const prefix = try regionPrefix(arena, key);
                try outputs.append(arena, try processFile(arena, input, try outputDir(), resolution(), prefix));
                radar_written = true;
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

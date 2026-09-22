//! Precip typing: fold precip-type codes into the radar reflectivity banding
//! model, so a frame carries rain / mixed / snow as well as dBZ.
//!
//! Two sources, chosen by region (`sourceFor`):
//!   CONUS  - the obs `precip_type` series (rain / mixed / snow)
//!   Alaska - MRMS PrecipFlag, read beside the radar grib (rain / snow only:
//!            MRMS has no mixed or sleet class)
//! Other MRMS regions (Hawaii, Caribbean, Guam) ship untyped.
//!
//! radcore already consumes typed bytes everywhere — it unfolds them
//! (products.zig value/describe), renders three colour runs, keeps types from
//! bleeding under magnification (recon.zig) and normalises them away before
//! optical flow (flow.zig). Nothing produced them until now.
//!
//! The byte layout is radcore's, from recon.zig bandOf/bandByte:
//!
//!     rain   1..88     byte = dBZ
//!     mixed  90..168   byte = clamp(dBZ + 80,  90, 168)
//!     snow   170..254  byte = clamp(dBZ + 160, 170, 254)
//!     89, 169, 255 are SEPARATORS — bandOf rejects them, never emit one
//!
//! Those helpers are private in radcore, so the folding is reimplemented here.
//! `test "fold round-trips through radcore"` pins it against radcore's public
//! `products.value`, so if the two ever drift the test fails rather than the
//! clients silently mis-decoding.
const std = @import("std");
const radcore = @import("radcore");
const gdal = @import("gdal.zig");
const stamp = @import("stamp.zig");
const manifest = @import("manifest.zig");
const handler = @import("handler.zig");

const log = std.log.scoped(.ptype);

/// Reject an obs frame older than this relative to the radar frame. Crystal's
/// production code had NO limit and would apply a week-old field forever; its
/// own rewrite settled on 30 minutes. obs publishes every 5 min.
pub const MAX_AGE_MS: i64 = 30 * std.time.ms_per_min;

/// Below this, leave the pixel in the rain band at its true value: the mixed
/// and snow bands cannot express under 10 dBZ (recon.zig bandByte adds +9 to
/// `lo` for t>0), so typing a 3 dBZ pixel as snow would clamp it UP to byte
/// 170 — inventing 7 dBZ of echo.
pub const MIN_TYPED_DBZ: u8 = 10;

pub const Band = enum(u8) {
    rain = 0,
    mixed = 1,
    snow = 2,

    /// obs precip_type codes: 1 rain, 2 storm, 3 snow, 4 sleet, 5 mixed.
    /// Storm is convective rain and stays rain for now. Sleet folds into mixed
    /// — the model carries three bands, not five. 0 = no obs reading.
    pub fn fromCode(code: u8) Band {
        return switch (code) {
            3 => .snow,
            4, 5 => .mixed,
            else => .rain, // 1 rain, 2 storm, 0 absent, and anything unexpected
        };
    }
};

/// Maps a source's raw code to a band. obs and MRMS number their classes
/// differently, so `apply` takes the mapper rather than assuming one table.
pub const Mapper = *const fn (u8) Band;

/// MRMS PrecipFlag codes (all regions share the table):
///   -3 no coverage   0 no precip   1 warm stratiform rain   3 SNOW
///    6 convective    7 rain+hail  10 cold stratiform rain
///   91 tropical/stratiform mix    96 tropical/convective mix
/// Only snow is a winter class; there is no mixed or sleet code, so MRMS
/// never yields the mixed band. -3 reads as 0 once warped to GDT_Byte (GDAL
/// clamps negatives), and both are "untyped" anyway.
pub fn mrmsBand(code: u8) Band {
    return if (code == 3) .snow else .rain;
}

/// dBZ byte -> banded byte. Mirrors radcore recon.zig bandByte.
pub fn fold(dbz: u8, band: Band) u8 {
    if (band == .rain) return dbz;
    if (dbz < MIN_TYPED_DBZ) return dbz; // see MIN_TYPED_DBZ
    const wide: u16 = dbz; // widen BEFORE adding: Crystal overflowed a u8 here
    return switch (band) {
        .rain => unreachable,
        .mixed => @intCast(std.math.clamp(wide + 80, 90, 168)),
        .snow => @intCast(std.math.clamp(wide + 160, 170, 254)),
    };
}

// ------------------------------------------------------------- the obs field

/// A decoded obs precip_type frame, ready to sample at radar pixel centres.
pub const Field = struct {
    codes: []u8,
    w: usize,
    h: usize,
    geo: [6]f64,

    /// Nearest obs code under a radar pixel centre, or 0 when the pixel falls
    /// outside the obs domain. Nearest-neighbour is not an approximation here:
    /// the codes are categorical and must never be interpolated (radcore
    /// core.zig:761 makes the same point about type-banded values).
    pub fn codeAt(self: *const Field, mx: f64, my: f64) u8 {
        const col = @floor((mx - self.geo[0]) / self.geo[1]);
        const row = @floor((my - self.geo[3]) / self.geo[5]);
        if (col < 0 or row < 0) return 0;
        const c: usize = @intFromFloat(col);
        const r: usize = @intFromFloat(row);
        if (c >= self.w or r >= self.h) return 0;
        return self.codes[r * self.w + c];
    }
};

/// Type a warped radar band in place. Returns how many pixels were typed as
/// something other than rain — worth logging, since "0" means the obs frame
/// resolved but contributed nothing, which looks the same as no obs at all.
pub fn apply(band: []u8, geo: [6]f64, w: usize, h: usize, field: *const Field, map: Mapper) usize {
    var typed: usize = 0;
    var row: usize = 0;
    while (row < h) : (row += 1) {
        const my = geo[3] + (@as(f64, @floatFromInt(row)) + 0.5) * geo[5];
        var col: usize = 0;
        while (col < w) : (col += 1) {
            const i = row * w + col;
            const dbz = band[i];
            if (dbz < MIN_TYPED_DBZ) continue; // also skips 0 = no data
            const mx = geo[0] + (@as(f64, @floatFromInt(col)) + 0.5) * geo[1];
            const b = map(field.codeAt(mx, my));
            if (b == .rain) continue;
            band[i] = fold(dbz, b);
            typed += 1;
        }
    }
    return typed;
}

// ----------------------------------------------------------------- resolving

/// Where the obs precip_type series lives. Derived from RAD_OUTPUT's parent
/// (".../rads" -> ".../obs/precip_type") so nothing new has to be configured,
/// but RAD_TYPE_SOURCE overrides it — including to a path that does not exist,
/// which is how you turn typing off without a deploy.
/// null when there is no basis to derive one — i.e. CLI mode, where RAD_OUTPUT
/// is unset. That is an ordinary state, not an error, so it must not log.
pub fn sourceDir(alloc: std.mem.Allocator) !?[]const u8 {
    if (handler.getenv("RAD_TYPE_SOURCE")) |explicit| return try alloc.dupe(u8, explicit);
    if (handler.getenv("RAD_OUTPUT") == null) return null;
    // Deliberately RAD_OUTPUT and not the caller's out_dir: the 5-minute fills
    // are written to ".../rads/5min", whose parent is ".../rads" — deriving
    // from that would look for ".../rads/obs/precip_type". It also means CLI
    // mode (no RAD_OUTPUT) skips typing unless RAD_TYPE_SOURCE points at a
    // local directory, which is how the tests drive it.
    const trimmed = std.mem.trimEnd(u8, try handler.outputDir(), "/");
    const parent = if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |i| trimmed[0..i] else trimmed;
    return try std.fmt.allocPrint(alloc, "{s}/obs/precip_type", .{parent});
}

const ManifestFrame = struct { id: []const u8 = "", time: []const u8 = "", url: []const u8 = "", bytes: i64 = 0 };
const Manifest = struct { product: []const u8 = "", updated_at: []const u8 = "", frames: []ManifestFrame = &.{} };

/// Newest frame id in `manifest_json` whose stamp is at or before `target` and
/// no older than MAX_AGE_MS. Split out so the selection rule is testable
/// without S3. Never picks a frame from the future — an archived frame typed
/// with observations that did not exist yet would be indefensible.
///
/// Parses properly rather than scanning for `"id":"`. A hand-rolled scan works
/// only while manifest.build keeps emitting JSON with no space after the colon,
/// and the failure mode is silent: typing just stops. Allocations land on the
/// caller's arena (same pattern as tiles.zig parseManifest).
pub fn pickFrame(alloc: std.mem.Allocator, manifest_json: []const u8, target: stamp.Stamp) ?[]const u8 {
    const m = std.json.parseFromSliceLeaky(Manifest, alloc, manifest_json, .{ .ignore_unknown_fields = true }) catch |err| {
        log.warn("precip_type manifest did not parse: {s}", .{@errorName(err)});
        return null;
    };
    const want = target.ms();
    var best: ?[]const u8 = null;
    var best_ms: i64 = 0;
    for (m.frames) |f| {
        if (!stamp.validId(f.id)) continue;
        var s: stamp.Stamp = undefined;
        @memcpy(&s.text, stamp.stampOfId(f.id)[0..15]);
        const ms = s.ms();
        if (ms > want or want - ms > MAX_AGE_MS) continue;
        if (best == null or ms > best_ms) {
            best = f.id;
            best_ms = ms;
        }
    }
    return best;
}

// ------------------------------------------------------------- MRMS PrecipFlag

pub const Source = enum { obs, mrms, none };

/// Which typing source a region's frames use, by the handler's id prefix.
/// RAD_TYPE_MRMS=0 turns the MRMS source off without a deploy.
pub fn sourceFor(id_prefix: []const u8) Source {
    if (id_prefix.len == 0) return .obs; // CONUS is the unprefixed region
    if (std.mem.eql(u8, id_prefix, "alaska_")) {
        if (handler.getenv("RAD_TYPE_MRMS")) |v| {
            if (std.mem.eql(u8, v, "0")) return .none;
        }
        return .mrms;
    }
    return .none;
}

const FLAG_PRODUCT = "PrecipFlag_00.00";

/// The PrecipFlag object for stamp `s`, beside the radar grib `radar_input`
/// (".../ALASKA/SeamlessHSR_00.00/20260922/MRMS_SeamlessHSR_00.00_...grib2.gz").
/// The day directory is rebuilt from `s`, NOT copied from the radar path: the
/// T-2 fallback for a 00:00 frame is 23:58 in the previous day's directory.
/// null when the path does not have the MRMS region/product/day layout (a
/// loose local grib), which just means "no flag to look for".
pub fn flagKey(alloc: std.mem.Allocator, radar_input: []const u8, s: stamp.Stamp) !?[]const u8 {
    const day_dir = std.fs.path.dirname(radar_input) orelse return null;
    const day = std.fs.path.basename(day_dir);
    if (day.len != 8) return null;
    for (day) |ch| if (!std.ascii.isDigit(ch)) return null;
    const product_dir = std.fs.path.dirname(day_dir) orelse return null;
    const region_dir = std.fs.path.dirname(product_dir) orelse return null;
    const st = s.slice();
    return try std.fmt.allocPrint(alloc, "{s}/{s}/{s}/MRMS_{s}_{s}.grib2.gz", .{
        region_dir, FLAG_PRODUCT, st[0..8], FLAG_PRODUCT, st,
    });
}

/// How far back to look. The flag for stamp T usually lands ~30 s AFTER the
/// radar frame for T, so T is often absent when the radar is processed and
/// T-2 is the normal hit. 4 min of lag is well inside MAX_AGE_MS.
const FLAG_LOOKBACK_MIN = [_]i64{ 0, 2, 4 };

/// Warp the newest PrecipFlag at or up to 4 min before `source` onto the radar
/// grid and return it as a Field the caller owns (free `codes`). null when
/// none of the probed stamps exist. Deliberately not the obs warm cache: each
/// radar frame wants its own flag, and that cache holds one path.
pub fn loadMrmsFlag(alloc: std.mem.Allocator, radar_input: []const u8, source: stamp.Stamp, res: f64) !?Field {
    // One full clear up front: a flag probed while still absent (T, just
    // before it landed) leaves a negative vsicurl entry that the partial
    // per-prefix clear does not drop, and a later frame may probe that key.
    if (std.mem.startsWith(u8, radar_input, "/vsi")) gdal.clearAllVsiCache();

    for (FLAG_LOOKBACK_MIN) |back| {
        const s = stamp.fromMs(source.ms() - back * std.time.ms_per_min) orelse continue;
        const key = (try flagKey(alloc, radar_input, s)) orelse return null;
        defer alloc.free(key);
        // "near": the codes are categorical. One attempt: absence is the
        // expected answer for T, not a transient to back off on.
        const warped = gdal.warpBandOpts(alloc, key, res, .{ .resample = "near", .attempts = 1 }) catch |err| switch (err) {
            error.OpenFailed => continue,
            else => return err,
        };
        log.info("MRMS PrecipFlag {s} typing {s} (lag {d}s)", .{ s.slice(), source.slice(), back * 60 });
        return .{
            .codes = warped.band,
            .w = @intCast(warped.max_x),
            .h = @intCast(warped.max_y),
            .geo = warped.geo_tran,
        };
    }
    log.info("no MRMS PrecipFlag within {d} min of {s}; untyped", .{ FLAG_LOOKBACK_MIN[FLAG_LOOKBACK_MIN.len - 1], source.slice() });
    return null;
}

// ------------------------------------------------------------- warm-frame cache

var cached_path: ?[]u8 = null;
var cached: ?Field = null;
const persistent = std.heap.c_allocator;

fn dropCache() void {
    if (cached_path) |p| persistent.free(p);
    if (cached) |f| persistent.free(f.codes);
    cached_path = null;
    cached = null;
}

/// Load the obs frame that types `target`, or null when there is none inside
/// the staleness window. Cached across invocations by path: obs publishes every
/// 5 minutes while radar frames arrive every 2, so the same frame types several
/// in a row and a warm container should not re-fetch it.
pub fn load(alloc: std.mem.Allocator, target: stamp.Stamp) !?*const Field {
    const dir = (try sourceDir(alloc)) orelse return null; // CLI mode: no typing
    defer alloc.free(dir);

    const mpath = try std.fmt.allocPrint(alloc, "{s}/manifest.json", .{dir});
    defer alloc.free(mpath);
    gdal.clearVsiCache(alloc, mpath);
    const mraw = (try gdal.vsiRead(alloc, mpath)) orelse {
        log.info("no precip_type manifest at {s}; frame stays untyped", .{dir});
        return null;
    };
    const mjson = try manifest.gunzipIfNeeded(alloc, mraw); // owns mraw
    defer alloc.free(mjson);

    const id = pickFrame(alloc, mjson, target) orelse {
        log.info("no precip_type frame within {d} min of {s}; untyped", .{ @divTrunc(MAX_AGE_MS, std.time.ms_per_min), target.slice() });
        return null;
    };

    const path = try std.fmt.allocPrint(alloc, "{s}/{s}.rad", .{ dir, id });
    defer alloc.free(path);
    if (cached_path) |p| {
        if (std.mem.eql(u8, p, path)) return &cached.?;
    }

    const raw = (try gdal.vsiRead(alloc, path)) orelse {
        log.warn("precip_type frame listed but unreadable: {s}", .{path});
        return null;
    };
    const rad = try manifest.gunzipIfNeeded(alloc, raw); // owns raw
    defer alloc.free(rad);
    const hd = radcore.store.parseRadHeader(rad) orelse {
        log.warn("precip_type frame has a bad header: {s}", .{path});
        return null;
    };

    const w: usize = @intCast(hd.max_x);
    const h: usize = @intCast(hd.max_y);
    const codes = try persistent.alloc(u8, w * h);
    errdefer persistent.free(codes);
    radcore.decodeBandPublic(&.{
        .geo_tran = hd.geo_tran,
        .max_x = hd.max_x,
        .max_y = hd.max_y,
        .original_size = hd.original_size,
        .compressed = rad.ptr + hd.stream_off,
        .compressed_len = hd.stream_len,
        .rle_version = hd.rle_version,
    }, codes);

    dropCache();
    cached_path = try persistent.dupe(u8, path);
    cached = .{ .codes = codes, .w = w, .h = h, .geo = hd.geo_tran };
    log.info("precip_type {s}: {d}x{d} typing {s}", .{ id, w, h, target.slice() });
    return &cached.?;
}

// --------------------------------------------------------------------- tests

const testing = std.testing;

test "code -> band: storm is rain, sleet folds into mixed" {
    try testing.expectEqual(Band.rain, Band.fromCode(1)); // rain
    try testing.expectEqual(Band.rain, Band.fromCode(2)); // storm — ignored for now
    try testing.expectEqual(Band.snow, Band.fromCode(3)); // snow
    try testing.expectEqual(Band.mixed, Band.fromCode(4)); // sleet -> mixed
    try testing.expectEqual(Band.mixed, Band.fromCode(5)); // mixed
    try testing.expectEqual(Band.rain, Band.fromCode(0)); // no reading
    try testing.expectEqual(Band.rain, Band.fromCode(200)); // never emitted, must not crash
}

test "fold round-trips through radcore's own decoder" {
    // The band offsets are private in radcore, so this is a second copy. Pin it
    // against the PUBLIC decoder: if the two ever drift, this fails here rather
    // than every client silently mis-reading dBZ.
    const rv = radcore.products.Encoding.reflectivity;
    var dbz: u8 = MIN_TYPED_DBZ;
    while (dbz <= 88) : (dbz += 1) {
        for ([_]Band{ .rain, .mixed, .snow }) |b| {
            const byte = fold(dbz, b);
            try testing.expectEqual(@as(f64, @floatFromInt(dbz)), radcore.products.value(rv, byte).?);
            // and the separators are never produced
            try testing.expect(byte != 89 and byte != 169 and byte != 255);
        }
    }
}

test "fold: band ranges, clamps, and the sub-10 dBZ guard" {
    try testing.expectEqual(@as(u8, 30), fold(30, .rain));
    try testing.expectEqual(@as(u8, 110), fold(30, .mixed));
    try testing.expectEqual(@as(u8, 190), fold(30, .snow));

    // Band floors.
    try testing.expectEqual(@as(u8, 90), fold(10, .mixed));
    try testing.expectEqual(@as(u8, 170), fold(10, .snow));

    // Ceilings: mixed tops at 168, NOT 170 (Crystal clamped to 170, which is
    // snow's first byte and renders transparent). Snow tops at 254, not 255.
    try testing.expectEqual(@as(u8, 168), fold(88, .mixed));
    try testing.expectEqual(@as(u8, 168), fold(200, .mixed));
    try testing.expectEqual(@as(u8, 254), fold(200, .snow));

    // Widened before the add — Crystal's `value + 160_u8` raised on a u8.
    try testing.expectEqual(@as(u8, 254), fold(255, .snow));

    // Under 10 dBZ the value is preserved rather than clamped up into a band.
    try testing.expectEqual(@as(u8, 3), fold(3, .snow));
    try testing.expectEqual(@as(u8, 3), fold(3, .mixed));
    try testing.expectEqual(@as(u8, 0), fold(0, .snow));
}

test "pickFrame: most recent at or before target, inside the window" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // Deliberately spaced after the colons: the selection must not depend on
    // manifest.build's exact spelling.
    const j =
        \\{"product": "precip_type", "frames": [
        \\{"id": "20260712-004000"}, {"id": "20260712-004500"},
        \\{"id": "20260712-005000"}, {"id": "20260712-005500"}]}
    ;
    const mk = struct {
        fn s(t: *const [15]u8) stamp.Stamp {
            var out: stamp.Stamp = undefined;
            @memcpy(&out.text, t);
            return out;
        }
    }.s;
    // Exact match wins.
    try testing.expectEqualStrings("20260712-005000", pickFrame(a, j, mk("20260712-005000")).?);
    // Otherwise the newest one at or BEFORE — never 005500 from the future.
    try testing.expectEqualStrings("20260712-005000", pickFrame(a, j, mk("20260712-005200")).?);
    try testing.expectEqualStrings("20260712-004500", pickFrame(a, j, mk("20260712-004900")).?);
    // Nothing at or before the target.
    try testing.expect(pickFrame(a, j, mk("20260712-003000")) == null);
    // Everything is stale: 005500 + 30 min < 013000.
    try testing.expect(pickFrame(a, j, mk("20260712-013000")) == null);
    // Exactly at the 30-minute edge still counts.
    try testing.expectEqualStrings("20260712-005500", pickFrame(a, j, mk("20260712-012500")).?);
    // Empty / malformed manifests yield nothing rather than crashing.
    try testing.expect(pickFrame(a, "{\"frames\":[]}", mk("20260712-005000")) == null);
    try testing.expect(pickFrame(a, "", mk("20260712-005000")) == null);
}

test "Field.codeAt: sub-pixel offset grids, and outside means untyped" {
    // A 4x3 obs grid on the canonical lattice, 1000 m pixels.
    var codes = [_]u8{
        1, 3, 3, 0,
        1, 5, 3, 0,
        4, 4, 0, 0,
    };
    const f = Field{ .codes = &codes, .w = 4, .h = 3, .geo = .{ 0, 1000, 0, 0, 0, -1000 } };

    // Pixel centres.
    try testing.expectEqual(@as(u8, 1), f.codeAt(500, -500));
    try testing.expectEqual(@as(u8, 3), f.codeAt(1500, -500));
    try testing.expectEqual(@as(u8, 5), f.codeAt(1500, -1500));
    try testing.expectEqual(@as(u8, 4), f.codeAt(500, -2500));

    // A radar grid offset by a fraction of a pixel still lands in the right
    // cell — this is the real geometry: radar sits ~0.75 px off the lattice.
    // Row 1 spans -1000..-2000, so the nudge has to stay inside it.
    try testing.expectEqual(@as(u8, 5), f.codeAt(1500 + 240, -1500 - 400));
    try testing.expectEqual(@as(u8, 5), f.codeAt(1500 - 490, -1500 + 490));
    // ...and a nudge that DOES cross the boundary lands in the next cell.
    try testing.expectEqual(@as(u8, 4), f.codeAt(1500 + 240, -1500 - 610));

    // Outside the domain in every direction -> 0, which maps to rain.
    try testing.expectEqual(@as(u8, 0), f.codeAt(-1, -500));
    try testing.expectEqual(@as(u8, 0), f.codeAt(500, 1));
    try testing.expectEqual(@as(u8, 0), f.codeAt(4001, -500));
    try testing.expectEqual(@as(u8, 0), f.codeAt(500, -3001));
}

test "apply: types only echo >= 10 dBZ, leaves the rest alone" {
    var codes = [_]u8{ 3, 5, 1, 0 }; // snow, mixed, rain, absent
    const f = Field{ .codes = &codes, .w = 4, .h = 1, .geo = .{ 0, 1000, 0, 0, 0, -1000 } };
    // Same geometry for the "radar" band so cells line up 1:1.
    var band = [_]u8{ 30, 30, 30, 30 };
    var n = apply(&band, .{ 0, 1000, 0, 0, 0, -1000 }, 4, 1, &f, Band.fromCode);
    try testing.expectEqual(@as(usize, 2), n); // only snow + mixed count
    try testing.expectEqualSlices(u8, &.{ 190, 110, 30, 30 }, &band);

    // Weak echo and nodata are untouched even under a snow code.
    var weak = [_]u8{ 9, 5, 0, 1 };
    n = apply(&weak, .{ 0, 1000, 0, 0, 0, -1000 }, 4, 1, &f, Band.fromCode);
    try testing.expectEqual(@as(usize, 0), n);
    try testing.expectEqualSlices(u8, &.{ 9, 5, 0, 1 }, &weak);
}

test "typed bytes survive a RAD3 round trip and decode to the right dBZ" {
    // Closes the loop the unit tests above cannot: fold() is correct in
    // isolation, but the frame still has to carry bytes >88 through radcore's
    // encoder and back without the RLE mangling them.
    const alloc = testing.allocator;
    var band = [_]u8{
        0, // no data
        30,                fold(30, .mixed),  fold(30, .snow),
        10,                fold(10, .mixed),  fold(10, .snow),
        88,                fold(88, .mixed),  fold(88, .snow),
    };
    const geo = [6]f64{ 0, 1000, 0, 0, 0, -1000 };
    const rad = try radcore.rad3.writeRadV3(alloc, 0, geo, @as(i32, band.len), 1, 0, &band);
    defer alloc.free(rad);

    const hd = radcore.store.parseRadHeader(rad) orelse return error.BadHeader;
    const out = try alloc.alloc(u8, band.len);
    defer alloc.free(out);
    radcore.decodeBandPublic(&.{
        .geo_tran = hd.geo_tran,
        .max_x = hd.max_x,
        .max_y = hd.max_y,
        .original_size = hd.original_size,
        .compressed = rad.ptr + hd.stream_off,
        .compressed_len = hd.stream_len,
        .rle_version = hd.rle_version,
    }, out);
    try testing.expectEqualSlices(u8, &band, out);

    // Every non-zero byte unfolds to the dBZ it was built from, and no byte
    // landed on a separator.
    const rv = radcore.products.Encoding.reflectivity;
    for (out) |b| {
        if (b == 0) continue;
        try testing.expect(b != 89 and b != 169 and b != 255);
        const dbz = radcore.products.value(rv, b).?;
        try testing.expect(dbz >= 10 and dbz <= 88);
    }
}

test "MRMS code -> band: only snow is a winter class" {
    try testing.expectEqual(Band.snow, mrmsBand(3));
    // Every rain variant stays rain — including 7 (rain + hail), which is
    // convective, not mixed-phase.
    for ([_]u8{ 1, 6, 7, 10, 91, 96 }) |code| try testing.expectEqual(Band.rain, mrmsBand(code));
    // No coverage (-3 clamps to 0 in GDT_Byte) and no precip are untyped.
    try testing.expectEqual(Band.rain, mrmsBand(0));
    // MRMS has no mixed class; nothing may map there, including obs's 4/5.
    for ([_]u8{ 2, 4, 5, 8, 9, 200, 255 }) |code| try testing.expect(mrmsBand(code) != .mixed);
}

test "sourceFor: CONUS -> obs, Alaska -> MRMS, other regions untyped" {
    try testing.expectEqual(Source.obs, sourceFor(""));
    try testing.expectEqual(Source.mrms, sourceFor("alaska_"));
    try testing.expectEqual(Source.none, sourceFor("hawaii_"));
    try testing.expectEqual(Source.none, sourceFor("carib_"));
    try testing.expectEqual(Source.none, sourceFor("guam_"));
}

test "flagKey: sibling PrecipFlag path, day directory rebuilt from the stamp" {
    const alloc = testing.allocator;
    const radar = "/vsis3/noaa-mrms-pds/ALASKA/SeamlessHSR_00.00/20260922/MRMS_SeamlessHSR_00.00_20260922-195000.grib2.gz";
    const mk = struct {
        fn s(t: *const [15]u8) stamp.Stamp {
            var out: stamp.Stamp = undefined;
            @memcpy(&out.text, t);
            return out;
        }
    }.s;

    const same = (try flagKey(alloc, radar, mk("20260922-195000"))).?;
    defer alloc.free(same);
    try testing.expectEqualStrings(
        "/vsis3/noaa-mrms-pds/ALASKA/PrecipFlag_00.00/20260922/MRMS_PrecipFlag_00.00_20260922-195000.grib2.gz",
        same,
    );

    // T-2 across midnight lands in the PREVIOUS day's directory; copying the
    // radar key's day would build a path that can never exist.
    const midnight = "/vsis3/noaa-mrms-pds/ALASKA/SeamlessHSR_00.00/20260923/MRMS_SeamlessHSR_00.00_20260923-000000.grib2.gz";
    const back = stamp.fromMs(mk("20260923-000000").ms() - 2 * std.time.ms_per_min).?;
    const prev = (try flagKey(alloc, midnight, back)).?;
    defer alloc.free(prev);
    try testing.expectEqualStrings(
        "/vsis3/noaa-mrms-pds/ALASKA/PrecipFlag_00.00/20260922/MRMS_PrecipFlag_00.00_20260922-235800.grib2.gz",
        prev,
    );

    // Local mirror of the bucket layout works the same way (CLI QA runs).
    const local = (try flagKey(alloc, "/tmp/mrms/ALASKA/SeamlessHSR_00.00/20260115/x.grib2.gz", mk("20260115-120000"))).?;
    defer alloc.free(local);
    try testing.expectEqualStrings("/tmp/mrms/ALASKA/PrecipFlag_00.00/20260115/MRMS_PrecipFlag_00.00_20260115-120000.grib2.gz", local);

    // A loose grib with no region/product/day layout has no sibling to find.
    try testing.expect((try flagKey(alloc, "/tmp/MRMS_SeamlessHSR_00.00_20260922-195000.grib2.gz", mk("20260922-195000"))) == null);
    try testing.expect((try flagKey(alloc, "x.grib2.gz", mk("20260922-195000"))) == null);
}

test "apply with the MRMS mapper: snow types, nothing becomes mixed" {
    // 3 snow, 10 cold stratiform rain, 1 warm rain, 0 no precip
    var codes = [_]u8{ 3, 10, 1, 0 };
    const f = Field{ .codes = &codes, .w = 4, .h = 1, .geo = .{ 0, 1000, 0, 0, 0, -1000 } };
    var band = [_]u8{ 30, 30, 30, 30 };
    const n = apply(&band, .{ 0, 1000, 0, 0, 0, -1000 }, 4, 1, &f, mrmsBand);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqualSlices(u8, &.{ 190, 30, 30, 30 }, &band);
}

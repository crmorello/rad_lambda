//! GDAL C API glue: in-process warp to a MEM dataset, VSI file IO (local
//! paths and /vsis3/ alike), directory listing. Port of the Crystal
//! GdalWarp/VsiFile modules — parity gate is byte-identical RAD output.
const std = @import("std");

pub const c = @cImport({
    @cInclude("gdal.h");
    @cInclude("gdal_utils.h");
    @cInclude("ogr_api.h");
    @cInclude("cpl_vsi.h");
    @cInclude("cpl_string.h");
    @cInclude("cpl_error.h");
    @cInclude("unistd.h");
    @cInclude("time.h");
});

pub const GdalError = error{
    OpenFailed,
    WarpOptionsRejected,
    WarpFailed,
    RasterIoFailed,
    VsiOpenFailed,
    VsiWriteFailed,
    OutOfMemory,
};

pub fn setup() void {
    c.GDALAllRegister();
}

pub const Warped = struct {
    geo_tran: [6]f64,
    max_x: i32,
    max_y: i32,
    no_data: u8,
    band: []u8,
};

/// Opens (gzip transparently via /vsigzip/), warps to EPSG:3857 at a fixed
/// resolution (mercator meters/pixel, "med" resampling) into a MEM dataset,
/// and reads band 1 as bytes. Caller frees `band`.
pub fn warpBand(alloc: std.mem.Allocator, path: []const u8, resolution: f64) !Warped {
    const gdal_path = if (std.mem.endsWith(u8, path, ".gz") and !std.mem.startsWith(u8, path, "/vsigzip/"))
        try std.fmt.allocPrintSentinel(alloc, "/vsigzip/{s}", .{path}, 0)
    else
        try alloc.dupeZ(u8, path);
    defer alloc.free(gdal_path);

    // GDALOpen with in-process retries, exponential backoff (1+2+...+32s
    // ~= 63s window). Prod-measured: NOAA's notification arrives up to
    // 15-90s BEFORE the object is fetchable, so most opens must wait.
    // Between attempts do a FULL VSICurlClearCache(): vsicurl caches the
    // failure, and the partial (per-prefix) clear demonstrably did NOT drop
    // the negative entry (attempts kept failing after the object appeared;
    // only invocations landing on fresh containers recovered — ~40% of
    // marks were lost to poisoned warm containers).
    var opened: c.GDALDatasetH = null;
    var attempt: usize = 0;
    while (attempt < 6) : (attempt += 1) {
        if (attempt > 0) {
            c.VSICurlClearCache();
            _ = c.usleep(@as(c_uint, 1_000_000) << @intCast(attempt - 1));
        }
        opened = c.GDALOpen(gdal_path.ptr, c.GA_ReadOnly);
        if (opened != null) break;
        std.debug.print("GDALOpen attempt {d} failed for {s}: {s}\n", .{
            attempt + 1, gdal_path, std.mem.span(c.CPLGetLastErrorMsg()),
        });
    }
    const src = opened orelse return GdalError.OpenFailed;
    defer _ = c.GDALClose(src);

    var res_buf: [64]u8 = undefined;
    const res: [:0]const u8 = std.fmt.bufPrintSentinel(&res_buf, "{d}", .{resolution}, 0) catch unreachable;
    const argv = [_:null]?[*:0]const u8{
        "-of", "MEM", "-t_srs", "EPSG:3857", "-r", "med", "-tr", res.ptr, res.ptr,
    };
    const options = c.GDALWarpAppOptionsNew(@ptrCast(@constCast(&argv)), null) orelse
        return GdalError.WarpOptionsRejected;
    defer c.GDALWarpAppOptionsFree(options);

    var srcs = [_]c.GDALDatasetH{src};
    var usage_error: c_int = 0;
    const warped = c.GDALWarp("", null, 1, &srcs, options, &usage_error) orelse
        return GdalError.WarpFailed;
    defer _ = c.GDALClose(warped);

    var out: Warped = undefined;
    out.max_x = c.GDALGetRasterXSize(warped);
    out.max_y = c.GDALGetRasterYSize(warped);
    _ = c.GDALGetGeoTransform(warped, &out.geo_tran);

    const band = c.GDALGetRasterBand(warped, 1);
    var has_no_data: c_int = 0;
    const nd = c.GDALGetRasterNoDataValue(band, &has_no_data);
    // Saturating float->u8 truncation: matches what Crystal's `.to_u8!`
    // compiles to on aarch64 (fcvtzu), where the shipped RADs were minted.
    out.no_data = if (nd <= 0) 0 else if (nd >= 255) 255 else @intFromFloat(nd);

    const len = @as(usize, @intCast(out.max_x)) * @as(usize, @intCast(out.max_y));
    out.band = try alloc.alloc(u8, len);
    errdefer alloc.free(out.band);
    const err = c.GDALRasterIO(band, c.GF_Read, 0, 0, out.max_x, out.max_y, out.band.ptr, out.max_x, out.max_y, c.GDT_Byte, 0, 0);
    if (err != c.CE_None) return GdalError.RasterIoFailed;
    return out;
}

/// Write through VSI — one code path for local files AND /vsis3/ (S3
/// credentials come from AWS_* env vars). Local relative dirs get mkdir -p.
pub fn vsiWrite(alloc: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    if (!std.mem.startsWith(u8, path, "/vsi")) {
        if (std.fs.path.dirname(path)) |dir| {
            const dir_z = try alloc.dupeZ(u8, dir);
            defer alloc.free(dir_z);
            _ = c.VSIMkdirRecursive(dir_z.ptr, 0o755);
        }
    }
    const path_z = try alloc.dupeZ(u8, path);
    defer alloc.free(path_z);
    // PUT headers ride on this exact path and are cleared after, so later
    // reads carry no custom header (the PUT happens inside VSIFCloseL for
    // /vsis3/). Content-Encoding for gzip-at-rest; Cache-Control on every
    // manifest.json so CloudFront's default "honor origin" behavior expires
    // it quickly — stale manifests (age > 1000 s on obs/*/manifest.json,
    // 2026-09-04) meant clients never saw new frames. Frames are immutable
    // and keep the CDN's long TTL.
    const gz = if (gzip_prefix) |p| std.mem.startsWith(u8, path, p) else false;
    const manifest = std.mem.endsWith(u8, path, "manifest.json");
    const headers: ?[*:0]const u8 = if (gz and manifest)
        "Content-Encoding: gzip,Cache-Control: max-age=15"
    else if (gz)
        "Content-Encoding: gzip"
    else if (manifest)
        "Cache-Control: max-age=15"
    else
        null;
    if (headers) |h| c.VSISetPathSpecificOption(path_z.ptr, "GDAL_HTTP_HEADERS", h);
    defer if (headers != null) c.VSIClearPathSpecificOptions(path_z.ptr);
    const file = c.VSIFOpenL(path_z.ptr, "wb") orelse return GdalError.VsiOpenFailed;
    const written = c.VSIFWriteL(bytes.ptr, 1, bytes.len, file);
    _ = c.VSIFCloseL(file);
    if (written != bytes.len) return GdalError.VsiWriteFailed;
}

/// Read a whole file through VSI (local or /vsis3/). null when the file
/// doesn't exist or can't be opened — the caller decides whether absence is
/// an error (for .flw production a missing previous frame is NORMAL: the
/// gap policy is "write nothing").
pub fn vsiRead(alloc: std.mem.Allocator, path: []const u8) !?[]u8 {
    const path_z = try alloc.dupeZ(u8, path);
    defer alloc.free(path_z);
    const file = c.VSIFOpenL(path_z.ptr, "rb") orelse return null;
    defer _ = c.VSIFCloseL(file);
    _ = c.VSIFSeekL(file, 0, 2); // SEEK_END
    const size = c.VSIFTellL(file);
    _ = c.VSIFSeekL(file, 0, 0); // SEEK_SET
    const buf = try alloc.alloc(u8, @intCast(size));
    errdefer alloc.free(buf);
    const got = c.VSIFReadL(buf.ptr, 1, buf.len, file);
    if (got != buf.len) {
        alloc.free(buf);
        return null;
    }
    return buf;
}

/// Drops GDAL's in-process vsicurl cache entries under `prefix`. The cache
/// remembers FAILURES and stale directory listings too — fatal in a warm
/// lambda container that lives for hours.
pub fn clearVsiCache(alloc: std.mem.Allocator, prefix: []const u8) void {
    if (!std.mem.startsWith(u8, prefix, "/vsi")) return;
    const prefix_z = alloc.dupeZ(u8, prefix) catch return;
    defer alloc.free(prefix_z);
    c.VSICurlPartialClearCache(prefix_z.ptr);
}

pub const DirEntry = struct {
    name: []u8,
    size: u64,
};

/// Directory entries with sizes via VSIOpenDir — one LIST call carries both
/// (S3 ListObjectsV2 returns Size; no per-object HEADs). For gzipped-at-rest
/// objects the size is the STORED size, i.e. what actually transfers.
pub fn readDirEntries(alloc: std.mem.Allocator, path: []const u8) ![]DirEntry {
    var entries: std.ArrayList(DirEntry) = .empty;
    errdefer entries.deinit(alloc);

    const path_z = try alloc.dupeZ(u8, path);
    defer alloc.free(path_z);
    const dir = c.VSIOpenDir(path_z.ptr, 0, null) orelse return entries.toOwnedSlice(alloc);
    defer c.VSICloseDir(dir);
    while (c.VSIGetNextDirEntry(dir)) |entry| {
        try entries.append(alloc, .{
            .name = try alloc.dupe(u8, std.mem.span(entry.*.pszName)),
            .size = entry.*.nSize,
        });
    }
    return entries.toOwnedSlice(alloc);
}

/// Directory entry names via VSIReadDir (local dirs and /vsis3/ prefixes
/// alike); missing dirs list empty.
pub fn readDir(alloc: std.mem.Allocator, path: []const u8) ![][]u8 {
    var names: std.ArrayList([]u8) = .empty;
    errdefer names.deinit(alloc);

    const path_z = try alloc.dupeZ(u8, path);
    defer alloc.free(path_z);
    const list = c.VSIReadDir(path_z.ptr);
    if (list == null) return names.toOwnedSlice(alloc);
    defer c.CSLDestroy(list);
    var i: usize = 0;
    while (list[i] != null) : (i += 1) {
        try names.append(alloc, try alloc.dupe(u8, std.mem.span(list[i].?)));
    }
    return names.toOwnedSlice(alloc);
}

/// Directory check via VSIReadDir: non-null only for listable directories.
/// (Not VSIStatL — glibc's stat64 is opaque under cImport so the stat buf
/// can't be stack-allocated on Linux; not std.c.stat — macOS hides it behind
/// versioned symbols. CLI-only; an empty dir misreads as a file, which the
/// CLI then reports as an open failure — fine for a grib input dir.)
pub fn isDir(alloc: std.mem.Allocator, path: []const u8) bool {
    const path_z = alloc.dupeZ(u8, path) catch return false;
    defer alloc.free(path_z);
    const list = c.VSIReadDir(path_z.ptr);
    if (list == null) return false;
    c.CSLDestroy(list);
    return true;
}

/// Registers Content-Encoding on all writes under `prefix` (S3 PUT headers
/// ride GDAL_HTTP_HEADERS; per-path so reads elsewhere are untouched).
/// Everything written under the prefix MUST then be gzipped.
/// Files under this prefix are stored gzipped with Content-Encoding metadata.
/// NOT a path-specific GDAL option anymore: that applied the header to every
/// request under the prefix — READS included — and custom headers on a
/// signed S3 GET are a footgun. vsiWrite scopes it to the exact file being
/// written and clears it after.
var gzip_prefix: ?[]u8 = null;

pub fn markPrefixGzip(alloc: std.mem.Allocator, prefix: []const u8) !void {
    gzip_prefix = try alloc.dupe(u8, prefix);
}

/// Unsigned S3 requests for a PUBLIC bucket (e.g. noaa-mrms-pds). Signed
/// reads of public buckets can be blocked by org SCPs / missing role grants
/// even though the bucket policy allows everyone — anonymous access
/// sidesteps IAM entirely. Per-path, so output-bucket writes stay signed.
pub fn markBucketUnsigned(alloc: std.mem.Allocator, bucket: []const u8) !void {
    const prefix = try std.fmt.allocPrintSentinel(alloc, "/vsis3/{s}", .{bucket}, 0);
    defer alloc.free(prefix);
    c.VSISetPathSpecificOption(prefix.ptr, "AWS_NO_SIGN_REQUEST", "YES");
}

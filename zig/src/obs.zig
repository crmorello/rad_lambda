//! H3 observation surface (parquet) -> RAD products, one per variable.
//!
//! Input: a pyarrow parquet of H3 cells — `hex_id` (string), `resolution`
//! (6..8, DISJOINT adaptive tiling: no cell has an ancestor in the set) and
//! observation variables. Output: `{out}/obs/{variable}/{stamp}.rad` plus a
//! `manifest.json` per variable, all on ONE target-aligned canonical pixel
//! lattice (origin snapped to multiples of the pixel size, so every product
//! — radar included once its warp adopts `-tap` — shares a grid).
//!
//! CLI mode only for now (`rad_lambda --obs <file.parquet> [out_dir]`); the
//! S3 trigger (`.parquet` key in handleEvent) is a later hook. Spec:
//! raydare/docs/obs-product.md.
const std = @import("std");
const gdal = @import("gdal.zig");
const manifest = @import("manifest.zig");
const stamp = @import("stamp.zig");
const handler = @import("handler.zig");
const radcore = @import("radcore");
const c = gdal.c;
const h3 = @cImport(@cInclude("h3api.h"));

const log = std.log.scoped(.obs);

pub const HALF_WORLD: f64 = 20037508.342789244;
/// Index-map sentinel: pixel covered by no cell.
pub const NONE: u32 = std.math.maxInt(u32);
/// Obs manifests list every frame in the prefix (research data is not a
/// rolling 10-minute window): ~400 days.
pub const MANIFEST_WINDOW_MS: i64 = 400 * 86_400_000;

// ---------------------------------------------------------------- encoding

/// u8 encodings. 0 is always "absent" (the pipeline's load-bearing sentinel:
/// RLE nodata, transparent in the shader); values clamp into 1..255.
pub const Encoding = enum {
    /// 1 + round((x + 40) * 2): -40..87 °C, 0.5 step
    thermo,
    /// 1 + round(x * 2.5): 0..100 %, 0.4 step
    percent,
    /// 1 + round((x - 950) * 2): 950..1077 hPa, 0.5 step
    pressure,
    /// 1 + round(x * 5): 0..50.8 m/s, 0.2 step
    wind_speed,
    /// atan2(sin, cos) -> 0..360°, 1 + round(deg / 1.5); sin = cos = 0 -> 0
    wind_dir,
    /// 1 + round(x / 5): 0..1270 W/m², 5 step
    solar,
    /// 1 + round(100 * log10(1 + x)): 0 -> 1, 300 mm/h -> 249
    precip_rate,
    /// raw categorical code (1..255); 0 stays absent
    code,
};

pub const Product = struct {
    name: [:0]const u8,
    enc: Encoding,
    /// Source column(s): one, or {sin, cos} for wind_dir.
    fields: []const [:0]const u8,
    /// Continuous fields are smoothed across cell plateaus before
    /// quantization (see smoothField); categorical codes never are.
    smooth: bool = true,
};

pub const products = [_]Product{
    .{ .name = "temperature", .enc = .thermo, .fields = &.{"temperature"} },
    .{ .name = "dewpoint", .enc = .thermo, .fields = &.{"dewpoint"} },
    .{ .name = "rh", .enc = .percent, .fields = &.{"rh"} },
    .{ .name = "pressure", .enc = .pressure, .fields = &.{"pressure"} },
    .{ .name = "wind_average", .enc = .wind_speed, .fields = &.{"wind_average"} },
    .{ .name = "wind_gust", .enc = .wind_speed, .fields = &.{"wind_gust"} },
    .{ .name = "wind_dir", .enc = .wind_dir, .fields = &.{ "wind_dir_sin", "wind_dir_cos" } },
    .{ .name = "solar_radiation", .enc = .solar, .fields = &.{"solar_radiation"} },
    .{ .name = "precip_rate", .enc = .precip_rate, .fields = &.{"precip_rate"} },
    .{ .name = "cloud_cover", .enc = .percent, .fields = &.{"cloud_cover"} },
    .{ .name = "tempest_pres_obs", .enc = .pressure, .fields = &.{"tempest_pres_obs"} },
    .{ .name = "precip_type", .enc = .code, .fields = &.{"precip_type"}, .smooth = false },
    .{ .name = "conditions_code", .enc = .code, .fields = &.{"conditions_code"}, .smooth = false },
};

/// Every parquet column the products read, in Table column order.
pub const field_names = [_][:0]const u8{
    "temperature",     "dewpoint",        "rh",           "pressure",
    "wind_average",    "wind_gust",       "wind_dir_sin", "wind_dir_cos",
    "solar_radiation", "precip_rate",     "cloud_cover",  "tempest_pres_obs",
    "precip_type",     "conditions_code",
};

fn fieldCol(name: []const u8) usize {
    for (field_names, 0..) |f, i| if (std.mem.eql(u8, f, name)) return i;
    unreachable; // products reference field_names only
}

/// round + clamp into 1..255; NaN -> 0.
pub fn clampByte(v: f64) u8 {
    if (std.math.isNan(v)) return 0;
    const r = @round(v);
    if (r < 1) return 1;
    if (r > 255) return 255;
    return @intFromFloat(r);
}

pub fn quantize(enc: Encoding, x: f64) u8 {
    if (std.math.isNan(x)) return 0;
    return switch (enc) {
        .thermo => clampByte(1 + (x + 40) * 2),
        .percent => clampByte(1 + x * 2.5),
        .pressure => clampByte(1 + (x - 950) * 2),
        .wind_speed => clampByte(1 + x * 5),
        .solar => clampByte(1 + x / 5),
        .precip_rate => clampByte(1 + 100 * std.math.log10(1 + @max(x, 0))),
        .code => if (x < 0.5) 0 else clampByte(x),
        .wind_dir => unreachable, // two-column: quantizeDir
    };
}

pub fn quantizeDir(sn: f64, cs: f64) u8 {
    if (std.math.isNan(sn) or std.math.isNan(cs)) return 0;
    if (sn == 0 and cs == 0) return 0;
    var deg = std.math.atan2(sn, cs) * 180.0 / std.math.pi;
    if (deg < 0) deg += 360;
    if (deg >= 360) deg -= 360;
    return clampByte(1 + deg / 1.5);
}

// -------------------------------------------------------------------- input

pub const Table = struct {
    cells: []h3.H3Index,
    res: []u8,
    /// cols[field][cell]; NaN = null / unset.
    cols: [field_names.len][]f32,

    pub fn deinit(self: *Table, alloc: std.mem.Allocator) void {
        alloc.free(self.cells);
        alloc.free(self.res);
        for (self.cols) |col| alloc.free(col);
        self.* = undefined;
    }
};

pub fn hasParquetDriver() bool {
    gdal.setup();
    return c.GDALGetDriverByName("Parquet") != null;
}

/// Read every feature: hex_id -> H3Index (unparseable ids are skipped with
/// a count), all product columns as f32 with NaN for null.
pub fn readTable(alloc: std.mem.Allocator, path: []const u8) !Table {
    gdal.setup();
    const cpath = try alloc.dupeZ(u8, path);
    defer alloc.free(cpath);

    const ds = c.GDALOpenEx(cpath.ptr, c.GDAL_OF_VECTOR | c.GDAL_OF_READONLY, null, null, null) orelse {
        log.err("open failed: {s}", .{path});
        return error.OpenFailed;
    };
    defer _ = c.GDALClose(ds);
    const layer = c.GDALDatasetGetLayer(ds, 0) orelse return error.NoLayer;
    const defn = c.OGR_L_GetLayerDefn(layer);

    const hex_i = c.OGR_FD_GetFieldIndex(defn, "hex_id");
    if (hex_i < 0) {
        log.err("missing column hex_id", .{});
        return error.MissingField;
    }
    var col_i: [field_names.len]c_int = undefined;
    for (field_names, 0..) |name, k| {
        col_i[k] = c.OGR_FD_GetFieldIndex(defn, name.ptr);
        if (col_i[k] < 0) {
            log.err("missing column {s}", .{name});
            return error.MissingField;
        }
    }

    var cells: std.ArrayList(h3.H3Index) = .empty;
    errdefer cells.deinit(alloc);
    var res: std.ArrayList(u8) = .empty;
    errdefer res.deinit(alloc);
    var cols: [field_names.len]std.ArrayList(f32) = @splat(.empty);
    errdefer for (&cols) |*col| col.deinit(alloc);

    var skipped: usize = 0;
    c.OGR_L_ResetReading(layer);
    while (c.OGR_L_GetNextFeature(layer)) |f| {
        defer c.OGR_F_Destroy(f);
        var idx: h3.H3Index = 0;
        const hs = c.OGR_F_GetFieldAsString(f, hex_i);
        if (h3.stringToH3(hs, &idx) != 0 or idx == 0 or h3.isValidCell(idx) == 0) {
            skipped += 1;
            continue;
        }
        try cells.append(alloc, idx);
        try res.append(alloc, @intCast(h3.getResolution(idx)));
        for (col_i, 0..) |ci, k| {
            const v: f32 = if (c.OGR_F_IsFieldSetAndNotNull(f, ci) != 0)
                @floatCast(c.OGR_F_GetFieldAsDouble(f, ci))
            else
                std.math.nan(f32);
            try cols[k].append(alloc, v);
        }
    }
    if (skipped > 0) log.warn("skipped {d} rows with unparseable hex_id", .{skipped});

    var out: Table = undefined;
    out.cells = try cells.toOwnedSlice(alloc);
    errdefer alloc.free(out.cells);
    out.res = try res.toOwnedSlice(alloc);
    errdefer alloc.free(out.res);
    for (&cols, 0..) |*col, k| out.cols[k] = try col.toOwnedSlice(alloc);
    return out;
}

// --------------------------------------------------------------------- grid

pub const Grid = struct {
    /// Top-left corner, EPSG:3857 meters. Multiples of `pw`.
    origin_x: f64,
    origin_y: f64,
    pw: f64,
    width: u32,
    height: u32,

    pub fn geoTran(self: Grid) [6]f64 {
        return .{ self.origin_x, self.pw, 0, self.origin_y, 0, -self.pw };
    }

    /// Meters -> continuous pixel coords (x right, y down).
    pub fn toPixel(self: Grid, x: f64, y: f64) [2]f64 {
        return .{ (x - self.origin_x) / self.pw, (self.origin_y - y) / self.pw };
    }

    pub fn len(self: Grid) usize {
        return @as(usize, self.width) * @as(usize, self.height);
    }
};

/// Target-aligned grid covering the bbox: origin snapped OUTWARD to
/// multiples of `pw`, dims cover the far edge.
pub fn snapGrid(min_x: f64, min_y: f64, max_x: f64, max_y: f64, pw: f64) Grid {
    const ox = @floor(min_x / pw) * pw;
    const oy = @ceil(max_y / pw) * pw;
    const w = @max(@ceil((max_x - ox) / pw), 1);
    const h = @max(@ceil((oy - min_y) / pw), 1);
    return .{
        .origin_x = ox,
        .origin_y = oy,
        .pw = pw,
        .width = @intFromFloat(w),
        .height = @intFromFloat(h),
    };
}

/// Radians -> EPSG:3857 meters (same constants as radcore geo.zig).
pub fn mercator(lat: f64, lng: f64) [2]f64 {
    return .{
        lng * HALF_WORLD / std.math.pi,
        (HALF_WORLD / std.math.pi) * @log(@tan(std.math.pi / 4.0 + lat / 2.0)),
    };
}

pub const IndexMap = struct {
    grid: Grid,
    /// Row-major cell index into Table.cells, or NONE.
    cell: []u32,
    /// Owning cell's H3 resolution per pixel (NO_RES where unowned) — the
    /// smoother picks its kernel per resolution class from this.
    res: []u8,

    pub fn deinit(self: *IndexMap, alloc: std.mem.Allocator) void {
        alloc.free(self.cell);
        alloc.free(self.res);
        self.* = undefined;
    }
};

pub const NO_RES: u8 = 255;
const MAX_RES: usize = 15;

/// Scanline-fill a convex polygon (pixel-space verts) into `map`, then
/// guarantee the pixel under `centroid` so sub-pixel cells never vanish
/// (res 8 is ~0.84 px at 1222.8 m). Pixel (col,row) is painted when its
/// center (col+.5,row+.5) lies inside.
///
/// Neighbouring hexagons interpolate their shared edge with the endpoints
/// swapped, so the two crossings can differ in the last bits and a pixel
/// center inside that ~1e-13 px sliver would be claimed by neither. Over
/// the ~9 M edge crossings of the CONUS sample the expected count is far
/// below one per file, none has been observed, and any that occurred would
/// be a lone unowned pixel with owned pixels on both sides — exactly what
/// `closeGaps` adopts. (A per-pixel `latLngToCell` sampler was tried: seam
/// -free by construction but 8x slower, and the holes it was written for
/// turned out to be source tiling gaps, not seams.)
pub fn paintPolygon(map: []u32, w: u32, h: u32, verts: []const [2]f64, centroid: [2]f64, idx: u32) void {
    const wf: f64 = @floatFromInt(w);
    const hf: f64 = @floatFromInt(h);
    var y_min: f64 = std.math.inf(f64);
    var y_max: f64 = -std.math.inf(f64);
    for (verts) |v| {
        y_min = @min(y_min, v[1]);
        y_max = @max(y_max, v[1]);
    }
    const r0 = @max(@floor(y_min), 0);
    const r1 = @min(@ceil(y_max), hf) - 1;
    var rf = r0;
    while (rf <= r1) : (rf += 1) {
        const yc = rf + 0.5;
        var xl: f64 = std.math.inf(f64);
        var xr: f64 = -std.math.inf(f64);
        for (verts, 0..) |a, i| {
            const b = verts[(i + 1) % verts.len];
            if ((a[1] <= yc) == (b[1] <= yc)) continue; // half-open: no double-count at vertices
            const x = a[0] + (yc - a[1]) * (b[0] - a[0]) / (b[1] - a[1]);
            xl = @min(xl, x);
            xr = @max(xr, x);
        }
        if (xl > xr) continue;
        const c0 = @max(@ceil(xl - 0.5), 0);
        const c1 = @min(@floor(xr - 0.5), wf - 1);
        if (c0 > c1) continue;
        const row = @as(usize, @intFromFloat(rf)) * w;
        var cf = c0;
        while (cf <= c1) : (cf += 1) map[row + @as(usize, @intFromFloat(cf))] = idx;
    }
    if (centroid[0] >= 0 and centroid[0] < wf and centroid[1] >= 0 and centroid[1] < hf) {
        const col: usize = @intFromFloat(@floor(centroid[0]));
        const row: usize = @intFromFloat(@floor(centroid[1]));
        map[row * w + col] = idx;
    }
}

fn boundaryMeters(cell: h3.H3Index, out: *[h3.MAX_CELL_BNDRY_VERTS][2]f64) ![]const [2]f64 {
    var bnd: h3.CellBoundary = undefined;
    if (h3.cellToBoundary(cell, &bnd) != 0) return error.H3Boundary;
    const n: usize = @intCast(bnd.numVerts);
    for (0..n) |i| out[i] = mercator(bnd.verts[i].lat, bnd.verts[i].lng);
    return out[0..n];
}

/// Rasterize all cells once into a cell-index map on a snapped grid.
/// Coarse resolutions paint first so finer cells win edge ties, then
/// `closeGaps` adopts the slivers the SOURCE tiling leaves between
/// resolutions (see there).
pub fn rasterize(alloc: std.mem.Allocator, cells: []const h3.H3Index, res: []const u8, pw: f64) !IndexMap {
    if (cells.len == 0) return error.NoCells;
    var min_x: f64 = std.math.inf(f64);
    var min_y: f64 = std.math.inf(f64);
    var max_x: f64 = -std.math.inf(f64);
    var max_y: f64 = -std.math.inf(f64);
    var buf: [h3.MAX_CELL_BNDRY_VERTS][2]f64 = undefined;
    for (cells) |cell| {
        for (try boundaryMeters(cell, &buf)) |m| {
            min_x = @min(min_x, m[0]);
            max_x = @max(max_x, m[0]);
            min_y = @min(min_y, m[1]);
            max_y = @max(max_y, m[1]);
        }
    }
    const grid = snapGrid(min_x, min_y, max_x, max_y, pw);
    const map = try alloc.alloc(u32, grid.len());
    errdefer alloc.free(map);
    @memset(map, NONE);

    var lo: u8 = 255;
    var hi: u8 = 0;
    for (res) |r| {
        lo = @min(lo, r);
        hi = @max(hi, r);
    }
    var lvl = lo;
    while (lvl <= hi) : (lvl += 1) {
        for (cells, res, 0..) |cell, r, i| {
            if (r != lvl) continue;
            const ms = try boundaryMeters(cell, &buf);
            var px: [h3.MAX_CELL_BNDRY_VERTS][2]f64 = undefined;
            for (ms, 0..) |m, k| px[k] = grid.toPixel(m[0], m[1]);
            var ll: h3.LatLng = undefined;
            if (h3.cellToLatLng(cell, &ll) != 0) return error.H3Center;
            const cm = mercator(ll.lat, ll.lng);
            paintPolygon(map, grid.width, grid.height, px[0..ms.len], grid.toPixel(cm[0], cm[1]), @intCast(i));
        }
        if (lvl == 255) break;
    }
    _ = try closeGaps(alloc, map, grid.width, grid.height);
    const res_px = try alloc.alloc(u8, grid.len());
    errdefer alloc.free(res_px);
    for (map, res_px) |ci, *r| r.* = if (ci == NONE) NO_RES else res[ci];
    return .{ .grid = grid, .cell = map, .res = res_px };
}

/// Adopt pixels that no cell owns but that are enclosed by cells, and report
/// how many were filled.
///
/// These gaps are in the SOURCE tiling, not in our sampling. H3's resolution
/// hierarchy is not an exact subdivision — the seven res-(r+1) children do
/// not tile their res-r parent — so a mixed-resolution cell set leaves
/// slivers belonging to no cell wherever the analysis switched resolution.
/// Measured on the CONUS sample: ~16.5k one-pixel gaps, of 2000 sampled
/// every single one sat inside a res-6 cell that had been subdivided into
/// res-7 children, and every one was ringed by present cells.
///
/// A pixel is adopted only when owned pixels sit on BOTH sides of it along
/// some axis. That closes interior slivers while leaving the data's outer
/// boundary exactly where it is — a one-sided rule would dilate the whole
/// coverage hull by a pixel. The same rule is the safety net for the
/// (vanishingly rare) floating-point seam a polygon fill can leave between
/// two neighbours: that too is a lone unowned pixel with owners either side.
fn closeGaps(alloc: std.mem.Allocator, map: []u32, w: u32, h: u32) !usize {
    if (w < 3 or h < 3) return 0;
    var fills: std.ArrayList(struct { at: usize, val: u32 }) = .empty;
    defer fills.deinit(alloc);
    var total: usize = 0;

    // Two snapshot passes: the first closes every single-pixel gap, the
    // second the two-pixel ones whose partner had to be filled first.
    // Collecting then applying keeps the result independent of scan order.
    for (0..2) |_| {
        fills.clearRetainingCapacity();
        var row: usize = 1;
        while (row + 1 < h) : (row += 1) {
            var col: usize = 1;
            while (col + 1 < w) : (col += 1) {
                const p = row * w + col;
                if (map[p] != NONE) continue;
                const l = map[p - 1];
                const r = map[p + 1];
                const u = map[p - w];
                const d = map[p + w];
                const v = if (l != NONE and r != NONE)
                    l
                else if (u != NONE and d != NONE)
                    u
                else
                    continue;
                try fills.append(alloc, .{ .at = p, .val = v });
            }
        }
        if (fills.items.len == 0) break;
        for (fills.items) |f| map[f.at] = f.val;
        total += fills.items.len;
    }
    return total;
}

// ---------------------------------------------------------------- smoothing

/// Box radius per H3 resolution: `scale` × half the cell's flat-to-flat
/// width in pixels. Mercator stretches lengths by 1/cos(lat), so the width
/// is taken at the domain's mean latitude. At 1222.8 m over CONUS with
/// scale 1: res 6 -> 3, res 7 -> 1, res 8 -> 0 (sub-pixel, left alone).
pub fn smoothRadii(scale: f64, pw: f64, lat_mean: f64) [MAX_RES + 1]u32 {
    var out: [MAX_RES + 1]u32 = @splat(0);
    if (scale <= 0) return out;
    const stretch = 1.0 / @cos(lat_mean);
    for (&out, 0..) |*r, res| {
        var edge_m: f64 = 0;
        if (h3.getHexagonEdgeLengthAvgM(@intCast(res), &edge_m) != 0) continue;
        const width_px = std.math.sqrt(3.0) * edge_m * stretch / pw;
        r.* = @intFromFloat(@round(scale * width_px / 2.0));
    }
    return out;
}

/// Latitude (radians) of a Mercator y.
fn latOfY(y: f64) f64 {
    return 2 * std.math.atan(@exp(y * std.math.pi / HALF_WORLD)) - std.math.pi / 2.0;
}

/// Windowed sums along rows: dst[y][x] = sum(src[y][x-r ..= x+r]), clipped
/// at the row ends. f64 running accumulator so the subtract/add drift stays
/// far below any quantization step.
fn boxRows(src: []const f32, dst: []f32, w: usize, h: usize, r: usize) void {
    for (0..h) |y| {
        const row = src[y * w ..][0..w];
        const out = dst[y * w ..][0..w];
        var acc: f64 = 0;
        for (0..@min(r + 1, w)) |x| acc += row[x];
        for (0..w) |x| {
            out[x] = @floatCast(acc);
            if (x + r + 1 < w) acc += row[x + r + 1];
            if (x >= r) acc -= row[x - r];
        }
    }
}

/// Windowed sums along columns, streamed row by row (cache friendly): keep
/// a per-column f64 accumulator, slide the window one row at a time.
fn boxCols(src: []const f32, dst: []f32, acc: []f64, w: usize, h: usize, r: usize) void {
    @memset(acc, 0);
    for (0..@min(r + 1, h)) |y| {
        for (src[y * w ..][0..w], acc) |v, *a| a.* += v;
    }
    for (0..h) |y| {
        for (dst[y * w ..][0..w], acc) |*o, a| o.* = @floatCast(a);
        if (y + r + 1 < h) for (src[(y + r + 1) * w ..][0..w], acc) |v, *a| {
            a.* += v;
        };
        if (y >= r) for (src[(y - r) * w ..][0..w], acc) |v, *a| {
            a.* -= v;
        };
    }
}

/// One separable box pass (radius r) in place: plane -> tmp (rows) -> plane (cols).
fn boxPass(plane: []f32, tmp: []f32, acc: []f64, w: usize, h: usize, r: usize) void {
    boxRows(plane, tmp, w, h, r);
    boxCols(tmp, plane, acc, w, h, r);
}

/// Smooth a field across cell plateaus, nodata-aware and resolution-adaptive.
///
/// `vals` holds one value per pixel (anything where `weight` is 0), `weight`
/// is 1 where the pixel is owned by a cell AND that cell has a value, `class`
/// is the owning cell's H3 resolution (NO_RES where unowned) and `radius`
/// the box radius per resolution. For every resolution class with a radius
/// > 0 the whole `vals·weight` and `weight` planes get two separable box
/// passes (≈ a triangle kernel); the normalized result is written back only
/// into pixels of that class that carry weight. So:
///   - the coverage hull never grows (unowned pixels are never written),
///   - null cells stay null and pull no neighbour toward them,
///   - fine-resolution regions get a small kernel, coarse plateaus a wide one,
///   - radius 0 (and scale 0) is the identity.
/// Returns a new plane; `vals` is left untouched.
pub fn smoothField(alloc: std.mem.Allocator, vals: []const f32, weight: []const f32, class: []const u8, radius: [MAX_RES + 1]u32, w: usize, h: usize) ![]f32 {
    const n = w * h;
    const out = try alloc.alloc(f32, n);
    errdefer alloc.free(out);
    @memcpy(out, vals);

    var present: [MAX_RES + 1]bool = @splat(false);
    for (class) |cl| {
        if (cl != NO_RES) present[cl] = true;
    }
    var any = false;
    for (present, radius) |pr, r| any = any or (pr and r > 0);
    if (!any) return out;

    const a = try alloc.alloc(f32, n); // value·weight, blurred
    defer alloc.free(a);
    const b = try alloc.alloc(f32, n); // weight, blurred
    defer alloc.free(b);
    const tmp = try alloc.alloc(f32, n);
    defer alloc.free(tmp);
    const acc = try alloc.alloc(f64, w);
    defer alloc.free(acc);

    for (present, radius, 0..) |pr, r, res| {
        if (!pr or r == 0) continue;
        for (a, b, vals, weight) |*av, *bv, v, wt| {
            av.* = v * wt;
            bv.* = wt;
        }
        for (0..2) |_| {
            boxPass(a, tmp, acc, w, h, r);
            boxPass(b, tmp, acc, w, h, r);
        }
        for (out, a, b, weight, class) |*o, av, bv, wt, cl| {
            if (cl == res and wt > 0 and bv > 0) o.* = av / bv;
        }
    }
    return out;
}

/// One product's u8 band over the index map. Continuous products are
/// smoothed in physical units first (`radius` all zero = off); categorical
/// ones and null cells go straight to the quantizer.
pub fn bandFor(alloc: std.mem.Allocator, table: *const Table, map: *const IndexMap, p: Product, radius: [MAX_RES + 1]u32) ![]u8 {
    const n = map.cell.len;
    const band = try alloc.alloc(u8, n);
    errdefer alloc.free(band);
    const cols = [2][]const f32{
        table.cols[fieldCol(p.fields[0])],
        table.cols[fieldCol(p.fields[if (p.fields.len > 1) 1 else 0])],
    };
    const nf: usize = p.fields.len;

    var any_radius = false;
    for (radius) |r| any_radius = any_radius or r > 0;
    if (!p.smooth or !any_radius) {
        for (map.cell, band) |ci, *out| {
            out.* = if (ci == NONE) 0 else if (p.enc == .wind_dir)
                quantizeDir(cols[0][ci], cols[1][ci])
            else
                quantize(p.enc, cols[0][ci]);
        }
        return band;
    }

    // Float planes: value per pixel and a shared weight (owned AND non-null).
    const weight = try alloc.alloc(f32, n);
    defer alloc.free(weight);
    var planes: [2][]f32 = undefined;
    var smoothed: [2][]f32 = undefined;
    var made: usize = 0;
    defer for (0..made) |k| {
        alloc.free(planes[k]);
        alloc.free(smoothed[k]);
    };
    for (0..nf) |k| {
        planes[k] = try alloc.alloc(f32, n);
        errdefer alloc.free(planes[k]);
        for (map.cell, planes[k], weight) |ci, *v, *wt| {
            if (ci == NONE) {
                v.* = 0;
                wt.* = 0;
                continue;
            }
            const x = cols[k][ci];
            const ok = !std.math.isNan(x) and (k == 0 or wt.* > 0);
            v.* = if (ok) x else 0;
            wt.* = if (ok) 1 else 0;
        }
        smoothed[k] = try smoothField(alloc, planes[k], weight, map.res, radius, map.grid.width, map.grid.height);
        made += 1;
    }
    // (For wind_dir the weight plane after field 1 is the AND of both
    // fields' validity, which is what quantizeDir needs.)
    for (band, weight, 0..) |*out, wt, i| {
        out.* = if (wt == 0) 0 else if (p.enc == .wind_dir)
            quantizeDir(smoothed[0][i], smoothed[1][i])
        else
            quantize(p.enc, smoothed[0][i]);
    }
    return band;
}

// ------------------------------------------------------------------- driver

/// `1788296100_slim.parquet` -> unix seconds -> stamp; otherwise the radar
/// `YYYYMMDD-HHMMSS` convention.
pub fn stampFromName(name: []const u8) ?stamp.Stamp {
    var i: usize = 0;
    while (i < name.len and std.ascii.isDigit(name[i])) i += 1;
    if (i == 10) {
        const secs = std.fmt.parseInt(i64, name[0..i], 10) catch return null;
        return stamp.fromMs(secs * 1000);
    }
    return stamp.fromFilename(name);
}

pub const Written = struct { path: []const u8, bytes: usize };

/// Full ingest: parquet -> 13 RAD products + manifests under `{out}/obs/`.
/// Returns the written .rad paths (caller frees each path and the slice).
pub fn ingest(alloc: std.mem.Allocator, input: []const u8, out_dir: []const u8, pw: f64) ![]Written {
    const s = stampFromName(std.fs.path.basename(input)) orelse return error.NoTimestampInFilename;

    var table = try readTable(alloc, input);
    defer table.deinit(alloc);
    var hist = [_]usize{0} ** 16;
    for (table.res) |r| hist[r] += 1;
    log.info("{d} cells (res6 {d}, res7 {d}, res8 {d}) stamp {s}", .{
        table.cells.len, hist[6], hist[7], hist[8], s.slice(),
    });

    var map = try rasterize(alloc, table.cells, table.res, pw);
    defer map.deinit(alloc);
    var covered: usize = 0;
    for (map.cell) |ci| covered += @intFromBool(ci != NONE);
    log.info("grid {d}x{d} @ {d} m origin ({d}, {d}); {d} px covered", .{
        map.grid.width, map.grid.height, pw, map.grid.origin_x, map.grid.origin_y, covered,
    });

    // Plateau smoothing (RAD_OBS_SMOOTH = kernel scale in cell half-widths;
    // 1.0 default, 0 off). Radii follow each cell's resolution.
    const scale: f64 = if (handler.getenv("RAD_OBS_SMOOTH")) |v|
        std.fmt.parseFloat(f64, v) catch 1.0
    else
        1.0;
    const lat_mean = latOfY(map.grid.origin_y - @as(f64, @floatFromInt(map.grid.height)) * pw / 2.0);
    const radius = smoothRadii(scale, pw, lat_mean);
    log.info("smoothing scale {d} at lat {d:.1}: radius res6 {d} px, res7 {d} px, res8 {d} px", .{
        scale, lat_mean * 180.0 / std.math.pi, radius[6], radius[7], radius[8],
    });

    var written: std.ArrayList(Written) = .empty;
    errdefer {
        for (written.items) |w| alloc.free(w.path);
        written.deinit(alloc);
    }
    const base = std.mem.trimEnd(u8, out_dir, "/");
    for (products) |p| {
        const band = try bandFor(alloc, &table, &map, p, radius);
        defer alloc.free(band);
        const rad = try radcore.writeRadV2(alloc, s.ms(), map.grid.geoTran(), @intCast(map.grid.width), @intCast(map.grid.height), 0, band);
        defer alloc.free(rad);

        const dir = try std.fmt.allocPrintSentinel(alloc, "{s}/obs/{s}", .{ base, p.name }, 0);
        defer alloc.free(dir);
        _ = c.VSIMkdirRecursive(dir.ptr, 0o755); // exists -> error, harmless
        const path = try std.fmt.allocPrint(alloc, "{s}/{s}.rad", .{ dir, s.slice() });
        errdefer alloc.free(path);
        try gdal.vsiWrite(alloc, path, rad);

        const prefix = try std.fmt.allocPrint(alloc, "/obs/{s}", .{p.name});
        defer alloc.free(prefix);
        try manifest.rebuild(alloc, dir, prefix, p.name, false, MANIFEST_WINDOW_MS);
        try written.append(alloc, .{ .path = path, .bytes = rad.len });
    }
    return written.toOwnedSlice(alloc);
}

// -------------------------------------------------------------------- tests

const testing = std.testing;

test "quantizer table endpoints, clamping, nodata" {
    const nan = std.math.nan(f64);
    // thermo: -40 -> 1, 87 -> 255, 20 -> 121, clamp both ends, null -> 0
    try testing.expectEqual(@as(u8, 1), quantize(.thermo, -40));
    try testing.expectEqual(@as(u8, 255), quantize(.thermo, 87));
    try testing.expectEqual(@as(u8, 121), quantize(.thermo, 20));
    try testing.expectEqual(@as(u8, 1), quantize(.thermo, -60));
    try testing.expectEqual(@as(u8, 255), quantize(.thermo, 120));
    try testing.expectEqual(@as(u8, 0), quantize(.thermo, nan));
    // percent
    try testing.expectEqual(@as(u8, 1), quantize(.percent, 0));
    try testing.expectEqual(@as(u8, 251), quantize(.percent, 100));
    // pressure
    try testing.expectEqual(@as(u8, 1), quantize(.pressure, 950));
    try testing.expectEqual(@as(u8, 255), quantize(.pressure, 1077));
    try testing.expectEqual(@as(u8, 127), quantize(.pressure, 1013));
    // wind speed
    try testing.expectEqual(@as(u8, 1), quantize(.wind_speed, 0));
    try testing.expectEqual(@as(u8, 255), quantize(.wind_speed, 50.8));
    try testing.expectEqual(@as(u8, 255), quantize(.wind_speed, 99));
    // solar
    try testing.expectEqual(@as(u8, 1), quantize(.solar, 0));
    try testing.expectEqual(@as(u8, 255), quantize(.solar, 1270));
    // precip rate: log scale
    try testing.expectEqual(@as(u8, 1), quantize(.precip_rate, 0));
    try testing.expectEqual(@as(u8, 31), quantize(.precip_rate, 1));
    try testing.expectEqual(@as(u8, 249), quantize(.precip_rate, 300));
    try testing.expectEqual(@as(u8, 1), quantize(.precip_rate, -2));
    // codes: raw; 0 stays absent
    try testing.expectEqual(@as(u8, 3), quantize(.code, 3));
    try testing.expectEqual(@as(u8, 15), quantize(.code, 15));
    try testing.expectEqual(@as(u8, 0), quantize(.code, 0));
    try testing.expectEqual(@as(u8, 0), quantize(.code, nan));
    // direction: N=1, E=61, S=121, W=181, calm -> 0
    try testing.expectEqual(@as(u8, 0), quantizeDir(0, 0));
    try testing.expectEqual(@as(u8, 1), quantizeDir(0, 1));
    try testing.expectEqual(@as(u8, 61), quantizeDir(1, 0));
    try testing.expectEqual(@as(u8, 121), quantizeDir(0, -1));
    try testing.expectEqual(@as(u8, 181), quantizeDir(-1, 0));
    try testing.expectEqual(@as(u8, 0), quantizeDir(nan, 1));
}

test "grid snapping: origin on the pixel lattice, dims cover the bbox" {
    const g = snapGrid(-1000.7, 250.2, 1499.1, 3020.9, 100);
    try testing.expectEqual(@as(f64, -1100), g.origin_x);
    try testing.expectEqual(@as(f64, 3100), g.origin_y);
    try testing.expectEqual(@as(f64, 0), @mod(g.origin_x, g.pw));
    try testing.expectEqual(@as(f64, 0), @mod(g.origin_y, g.pw));
    try testing.expectEqual(@as(u32, 26), g.width); // -1100 + 26*100 = 1500 >= 1499.1
    try testing.expectEqual(@as(u32, 29), g.height); // 3100 - 29*100 = 200 <= 250.2
    const gt = g.geoTran();
    try testing.expectEqual(@as(f64, -100), gt[5]);
    // two products on different bboxes land on the same lattice
    const g2 = snapGrid(-80.5, 1000, 4000, 1900, 100);
    try testing.expectEqual(@as(f64, 0), @mod(g2.origin_x - g.origin_x, g.pw));
    try testing.expectEqual(@as(f64, 0), @mod(g2.origin_y - g.origin_y, g.pw));
}

test "rasterize: a contiguous res-6 patch has no interior holes" {
    // Gapless input must rasterize gapless (fill + closeGaps end to end).
    var origin: h3.H3Index = 0;
    try testing.expectEqual(@as(u32, 0), h3.stringToH3("86444826fffffff", &origin));
    var disk: [19]h3.H3Index = @splat(0); // gridDisk k=2 = 1 + 6 + 12
    try testing.expectEqual(@as(u32, 0), h3.gridDisk(origin, 2, &disk));

    var cells: std.ArrayList(h3.H3Index) = .empty;
    defer cells.deinit(testing.allocator);
    var res: std.ArrayList(u8) = .empty;
    defer res.deinit(testing.allocator);
    for (disk) |cell| {
        if (cell == 0) continue; // pentagon neighbourhoods leave holes in the disk
        try cells.append(testing.allocator, cell);
        try res.append(testing.allocator, 6);
    }
    try testing.expect(cells.items.len >= 7);

    var map = try rasterize(testing.allocator, cells.items, res.items, 1222.8);
    defer map.deinit(testing.allocator);

    const w = map.grid.width;
    var enclosed: usize = 0;
    var row: usize = 1;
    while (row + 1 < map.grid.height) : (row += 1) {
        var col: usize = 1;
        while (col + 1 < w) : (col += 1) {
            const p = row * w + col;
            if (map.cell[p] != NONE) continue;
            if (map.cell[p - 1] != NONE and map.cell[p + 1] != NONE and
                map.cell[p - w] != NONE and map.cell[p + w] != NONE) enclosed += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), enclosed);
}

test "polygon fill: convex square, sub-pixel centroid, disjoint neighbors, clipping" {
    var map: [100]u32 = @splat(NONE);
    // square [2,5]x[2,5] px -> pixels cols 2..4, rows 2..4
    paintPolygon(&map, 10, 10, &.{ .{ 2, 2 }, .{ 5, 2 }, .{ 5, 5 }, .{ 2, 5 } }, .{ 3.5, 3.5 }, 7);
    var n: usize = 0;
    for (map, 0..) |v, p| {
        const col = p % 10;
        const row = p / 10;
        const inside = col >= 2 and col <= 4 and row >= 2 and row <= 4;
        try testing.expectEqual(if (inside) @as(u32, 7) else NONE, v);
        n += @intFromBool(v == 7);
    }
    try testing.expectEqual(@as(usize, 9), n);

    // tiny cell (no pixel center inside) still lands on its centroid pixel
    @memset(&map, NONE);
    paintPolygon(&map, 10, 10, &.{ .{ 7.2, 7.2 }, .{ 7.4, 7.2 }, .{ 7.4, 7.4 }, .{ 7.2, 7.4 } }, .{ 7.3, 7.3 }, 1);
    for (map, 0..) |v, p| try testing.expectEqual(if (p == 7 * 10 + 7) @as(u32, 1) else NONE, v);

    // disjoint neighbors sharing the edge x=3 never overwrite each other
    @memset(&map, NONE);
    paintPolygon(&map, 10, 10, &.{ .{ 0, 0 }, .{ 3, 0 }, .{ 3, 3 }, .{ 0, 3 } }, .{ 1.5, 1.5 }, 0);
    paintPolygon(&map, 10, 10, &.{ .{ 3, 0 }, .{ 6, 0 }, .{ 6, 3 }, .{ 3, 3 } }, .{ 4.5, 1.5 }, 1);
    for (0..3) |row| {
        for (0..3) |col| try testing.expectEqual(@as(u32, 0), map[row * 10 + col]);
        for (3..6) |col| try testing.expectEqual(@as(u32, 1), map[row * 10 + col]);
        try testing.expectEqual(NONE, map[row * 10 + 6]);
    }

    // clipped: polygon hanging off the grid corner paints only in-bounds pixels
    @memset(&map, NONE);
    paintPolygon(&map, 10, 10, &.{ .{ -2, -2 }, .{ 1, -2 }, .{ 1, 1 }, .{ -2, 1 } }, .{ -0.5, -0.5 }, 2);
    for (map, 0..) |v, p| try testing.expectEqual(if (p == 0) @as(u32, 2) else NONE, v);
}

test "hexagon fill via h3: finer wins over coarser, sub-pixel res 8 keeps its centroid pixel" {
    var parent: h3.H3Index = 0;
    try testing.expectEqual(@as(u32, 0), h3.stringToH3("86444826fffffff", &parent));
    var child: h3.H3Index = 0;
    try testing.expectEqual(@as(u32, 0), h3.cellToCenterChild(parent, 8, &child));
    const cells = [_]h3.H3Index{ parent, child }; // contrived: real input is disjoint
    const res = [_]u8{ 6, 8 };
    var map = try rasterize(testing.allocator, &cells, &res, 1222.8);
    defer map.deinit(testing.allocator);
    const k = map.grid.origin_x / 1222.8; // origin sits on the pixel lattice
    try testing.expectApproxEqAbs(@round(k), k, 1e-9);
    var n6: usize = 0;
    var n8: usize = 0;
    for (map.cell) |v| {
        n6 += @intFromBool(v == 0);
        n8 += @intFromBool(v == 1);
    }
    try testing.expect(n6 >= 15 and n6 <= 60); // ~41 px per res-6 cell in Mercator at CONUS latitudes
    try testing.expect(n8 >= 1 and n8 <= 2); // sub-pixel: centroid (+ at most one span pixel)
    var ll: h3.LatLng = undefined;
    _ = h3.cellToLatLng(child, &ll);
    const m = mercator(ll.lat, ll.lng);
    const px = map.grid.toPixel(m[0], m[1]);
    const p = @as(usize, @intFromFloat(@floor(px[1]))) * map.grid.width + @as(usize, @intFromFloat(@floor(px[0])));
    try testing.expectEqual(@as(u32, 1), map.cell[p]);
}

test "closeGaps: encloses interior slivers, never grows the outer boundary" {
    const N = NONE;
    // 5x5: an interior single-pixel gap, a two-pixel gap, and a notch on the
    // outer edge that must stay empty.
    var map = [_]u32{
        N, N, N, N, N,
        N, 7, 7, 7, N,
        N, 7, N, 7, N,
        N, 7, 7, 7, N,
        N, N, N, N, N,
    };
    const filled = try closeGaps(testing.allocator, &map, 5, 5);
    try testing.expectEqual(@as(usize, 1), filled);
    try testing.expectEqual(@as(u32, 7), map[2 * 5 + 2]);
    // every border pixel is untouched: the coverage hull did not dilate
    for (0..5) |i| {
        try testing.expectEqual(N, map[i]);
        try testing.expectEqual(N, map[4 * 5 + i]);
        try testing.expectEqual(N, map[i * 5]);
        try testing.expectEqual(N, map[i * 5 + 4]);
    }

    // A two-pixel gap needs the second pass.
    var two = [_]u32{
        N, N, N, N, N,
        N, 3, 3, 3, N,
        N, 3, N, 3, N,
        N, 3, N, 3, N,
        N, 3, 3, 3, N,
        N, N, N, N, N,
    };
    const n2 = try closeGaps(testing.allocator, &two, 5, 6);
    try testing.expectEqual(@as(usize, 2), n2);
    try testing.expectEqual(@as(u32, 3), two[2 * 5 + 2]);
    try testing.expectEqual(@as(u32, 3), two[3 * 5 + 2]);
}

test "smoothRadii: adaptive per resolution at 1222.8 m over CONUS" {
    const r = smoothRadii(1.0, 1222.8, 40.0 * std.math.pi / 180.0);
    try testing.expectEqual(@as(u32, 3), r[6]);
    try testing.expectEqual(@as(u32, 1), r[7]);
    try testing.expectEqual(@as(u32, 0), r[8]);
    const off = smoothRadii(0, 1222.8, 0.7);
    for (off) |v| try testing.expectEqual(@as(u32, 0), v);
}

test "smoothField: constant stays constant, hull never grows, radius 0 is identity" {
    const W = 12;
    const H = 10;
    var vals: [W * H]f32 = @splat(0);
    var wt: [W * H]f32 = @splat(0);
    var cls: [W * H]u8 = @splat(NO_RES);
    for (2..H - 2) |y| for (3..W - 3) |x| {
        vals[y * W + x] = 10;
        wt[y * W + x] = 1;
        cls[y * W + x] = 6;
    };
    var radius: [MAX_RES + 1]u32 = @splat(0);
    radius[6] = 3;
    const out = try smoothField(testing.allocator, &vals, &wt, &cls, radius, W, H);
    defer testing.allocator.free(out);
    for (out, wt) |o, w| {
        if (w > 0) try testing.expectApproxEqAbs(@as(f32, 10), o, 1e-4) else try testing.expectEqual(@as(f32, 0), o);
    }
    const same = try smoothField(testing.allocator, &vals, &wt, &cls, @splat(0), W, H);
    defer testing.allocator.free(same);
    try testing.expectEqualSlices(f32, &vals, same);
}

test "smoothField: a plateau step becomes a monotone ramp; nulls excluded and kept" {
    const W = 20;
    const H = 5;
    var vals: [W * H]f32 = undefined;
    var wt: [W * H]f32 = @splat(1);
    const cls: [W * H]u8 = @splat(6);
    for (0..H) |y| for (0..W) |x| {
        vals[y * W + x] = if (x < W / 2) 0 else 10;
    };
    // one null cell in the high plateau, on a different row than the one we
    // check for monotonicity (its own output stays 0 by design)
    const hole = 4 * W + 15;
    wt[hole] = 0;
    vals[hole] = 0;
    var radius: [MAX_RES + 1]u32 = @splat(0);
    radius[6] = 2;
    const out = try smoothField(testing.allocator, &vals, &wt, &cls, radius, W, H);
    defer testing.allocator.free(out);
    const row = out[2 * W ..][0..W];
    for (1..W) |x| try testing.expect(row[x] >= row[x - 1] - 1e-5); // monotone
    try testing.expectApproxEqAbs(@as(f32, 0), row[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 10), row[W - 1], 1e-5);
    try testing.expect(row[W / 2 - 1] > 0.5 and row[W / 2] < 9.5); // actually blended
    try testing.expectEqual(@as(f32, 0), out[hole]); // null not filled
    try testing.expectApproxEqAbs(@as(f32, 10), out[hole - 1], 1e-4); // and not dragging neighbours
}

test "bandFor: categorical bypasses smoothing; wind_dir averages sin/cos" {
    const W = 21; // two box passes of r=2 reach 4 px: the ends stay pure
    const H = 3;
    var t: Table = undefined;
    // two cells: 0 = north wind (sin 0, cos 1) / code 2 ; 1 = east wind (sin 1, cos 0) / code 5
    const cells = [_]h3.H3Index{ 1, 2 };
    const res = [_]u8{ 6, 6 };
    t.cells = @constCast(&cells);
    t.res = @constCast(&res);
    var colbuf: [field_names.len][2]f32 = undefined;
    for (&colbuf) |*cb| cb.* = .{ 0, 0 };
    colbuf[fieldCol("wind_dir_sin")] = .{ 0, 1 };
    colbuf[fieldCol("wind_dir_cos")] = .{ 1, 0 };
    colbuf[fieldCol("precip_type")] = .{ 2, 5 };
    for (&t.cols, &colbuf) |*c_, *cb| c_.* = cb;
    var cell: [W * H]u32 = undefined;
    var rp: [W * H]u8 = @splat(6);
    for (0..H) |y| for (0..W) |x| {
        cell[y * W + x] = if (x < W / 2) 0 else 1;
    };
    var map = IndexMap{ .grid = .{ .origin_x = 0, .origin_y = 0, .pw = 1, .width = W, .height = H }, .cell = &cell, .res = &rp };
    var radius: [MAX_RES + 1]u32 = @splat(0);
    radius[6] = 2;

    const codes = try bandFor(testing.allocator, &t, &map, products[11], radius); // precip_type
    defer testing.allocator.free(codes);
    try testing.expectEqual(@as(u8, 2), codes[W + 1]);
    try testing.expectEqual(@as(u8, 5), codes[W + W - 2]);
    try testing.expectEqual(@as(u8, 2), codes[W + W / 2 - 1]); // hard edge kept

    const dir = try bandFor(testing.allocator, &t, &map, products[6], radius); // wind_dir
    defer testing.allocator.free(dir);
    try testing.expectEqual(@as(u8, 1), dir[W + 0]); // N far from the edge
    try testing.expectEqual(@as(u8, 61), dir[W + W - 1]); // E far from the edge
    // sin/cos blend across the boundary -> intermediate (north-easterly) byte
    const mid = dir[W + W / 2];
    try testing.expect(mid > 1 and mid < 61);
}

test "stamp from epoch filename" {
    const s = stampFromName("1788296100_slim.parquet").?;
    try testing.expectEqualStrings("20260901-205500", s.slice()); // 2026-09-01T20:55:00Z
    try testing.expectEqual(@as(i64, 1788296100_000), s.ms());
    try testing.expectEqualStrings("20260901-093000", stampFromName("20260901-093000.parquet").?.slice());
    try testing.expect(stampFromName("slim.parquet") == null);
}

test "parquet read (needs RAD_OBS_SAMPLE + GDAL Parquet driver)" {
    const path = handler.getenv("RAD_OBS_SAMPLE") orelse {
        log.warn("RAD_OBS_SAMPLE unset; skipping parquet read test", .{});
        return;
    };
    if (!hasParquetDriver()) {
        log.warn("GDAL lacks the Parquet driver; skipping parquet read test", .{});
        return;
    }
    var t = try readTable(testing.allocator, path);
    defer t.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 551_628), t.cells.len);
    var hist = [_]usize{0} ** 16;
    for (t.res) |r| hist[r] += 1;
    try testing.expectEqual(@as(usize, 294_745), hist[6]);
    try testing.expectEqual(@as(usize, 171_798), hist[7]);
    try testing.expectEqual(@as(usize, 85_085), hist[8]);
    // first row: 86444826fffffff, temperature 36.5, precip_type 1
    try testing.expectEqual(@as(f32, 36.5), t.cols[fieldCol("temperature")][0]);
    try testing.expectEqual(@as(f32, 1), t.cols[fieldCol("precip_type")][0]);
}

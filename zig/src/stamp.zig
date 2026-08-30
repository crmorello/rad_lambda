//! "YYYYMMDD-HHMMSS" stamps — the pipeline's time currency (filenames, frame
//! ids, RAD header ms). Pure string+arithmetic; no date library.
const std = @import("std");

pub const Stamp = struct {
    text: [15]u8,

    pub fn slice(self: *const Stamp) []const u8 {
        return &self.text;
    }

    fn int(self: *const Stamp, start: usize, len: usize) i64 {
        var v: i64 = 0;
        for (self.text[start .. start + len]) |ch| v = v * 10 + (ch - '0');
        return v;
    }

    /// Unix milliseconds (days-from-civil, UTC).
    pub fn ms(self: *const Stamp) i64 {
        const y = self.int(0, 4);
        const mo = self.int(4, 2);
        const d = self.int(6, 2);
        const h = self.int(9, 2);
        const mi = self.int(11, 2);
        const s = self.int(13, 2);

        const yy = if (mo <= 2) y - 1 else y;
        const era = @divFloor(yy, 400);
        const yoe = yy - era * 400;
        const mp = if (mo > 2) mo - 3 else mo + 9;
        const doy = @divFloor(153 * mp + 2, 5) + d - 1;
        const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
        const days = era * 146097 + doe - 719468;
        return (((days * 24 + h) * 60 + mi) * 60 + s) * 1000;
    }

    /// The pipeline serves 10-minute slices (spec §12): minute % 10 == 0 and
    /// second == 0.
    pub fn onSliceGrid(self: *const Stamp) bool {
        return self.text[12] == '0' and self.text[13] == '0' and self.text[14] == '0';
    }

    /// "YYYY-MM-DDTHH:MM:SSZ" (matches Crystal Time#to_rfc3339).
    pub fn rfc3339(self: *const Stamp) [20]u8 {
        const t = &self.text;
        var out: [20]u8 = undefined;
        _ = std.fmt.bufPrint(&out, "{s}-{s}-{s}T{s}:{s}:{s}Z", .{
            t[0..4], t[4..6], t[6..8], t[9..11], t[11..13], t[13..15],
        }) catch unreachable;
        return out;
    }
};

/// Inverse of Stamp.ms(): unix milliseconds -> stamp (UTC, civil-from-days).
/// Sub-second precision is dropped. null for negative times.
pub fn fromMs(in_ms: i64) ?Stamp {
    if (in_ms < 0) return null;
    const total_s = @divFloor(in_ms, 1000);
    const days = @divFloor(total_s, 86400);
    const secs: u64 = @intCast(total_s - days * 86400);
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const mo = if (mp < 10) mp + 3 else mp - 9;
    const yy = if (mo <= 2) y + 1 else y;
    var s: Stamp = undefined;
    // u64 casts: zig's zero-padded {d} prints a sign for signed types.
    _ = std.fmt.bufPrint(&s.text, "{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}", .{
        @as(u64, @intCast(yy)), @as(u64, @intCast(mo)), @as(u64, @intCast(d)),
        secs / 3600,            (secs / 60) % 60,       secs % 60,
    }) catch return null;
    return s;
}

/// First \d{8}-\d{6} occurrence in a filename (MRMS embeds the data time).
pub fn fromFilename(name: []const u8) ?Stamp {
    if (name.len < 15) return null;
    var i: usize = 0;
    outer: while (i + 15 <= name.len) : (i += 1) {
        if (name[i + 8] != '-') continue;
        for (name[i .. i + 8]) |ch| {
            if (!std.ascii.isDigit(ch)) continue :outer;
        }
        for (name[i + 9 .. i + 15]) |ch| {
            if (!std.ascii.isDigit(ch)) continue :outer;
        }
        var s: Stamp = undefined;
        @memcpy(&s.text, name[i .. i + 15]);
        return s;
    }
    return null;
}

/// Stamp from a frame id ("20260714-174000" or "alaska_20260714-174000"):
/// the part after the last '_'.
pub fn stampOfId(id: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, id, '_')) |idx| return id[idx + 1 ..];
    return id;
}

/// "^([a-z0-9]+_)?\d{8}-\d{6}$" — frame id filter for manifest rebuilds.
pub fn validId(id: []const u8) bool {
    var rest = id;
    if (std.mem.lastIndexOfScalar(u8, id, '_')) |idx| {
        if (idx == 0) return false;
        for (id[0..idx]) |ch| {
            if (!(std.ascii.isDigit(ch) or (ch >= 'a' and ch <= 'z'))) return false;
        }
        rest = id[idx + 1 ..];
    }
    if (rest.len != 15 or rest[8] != '-') return false;
    for (rest[0..8]) |ch| if (!std.ascii.isDigit(ch)) return false;
    for (rest[9..15]) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

test "stamp parse + ms + grid" {
    const s = fromFilename("MRMS_SeamlessHSR_00.00_20260712-005000.grib2.gz") orelse return error.NoStamp;
    try std.testing.expectEqualStrings("20260712-005000", s.slice());
    try std.testing.expectEqual(@as(i64, 1783817400000), s.ms()); // 2026-07-12T00:50:00Z
    try std.testing.expect(s.onSliceGrid());
    try std.testing.expectEqualStrings("2026-07-12T00:50:00Z", &s.rfc3339());

    const off = fromFilename("x_20260712-005200.grib2") orelse return error.NoStamp;
    try std.testing.expect(!off.onSliceGrid());
    try std.testing.expect(fromFilename("no-stamp-here.grib2") == null);

    // epoch sanity: the classic reference date
    var epoch: Stamp = undefined;
    @memcpy(&epoch.text, "19700101-000000");
    try std.testing.expectEqual(@as(i64, 0), epoch.ms());
}

test "fromMs round trip (the .flw prev-stamp derivation)" {
    const s = fromFilename("x_20260712-005000.grib2") orelse return error.NoStamp;
    const back = fromMs(s.ms()) orelse return error.FromMsFailed;
    try std.testing.expectEqualStrings(s.slice(), back.slice());
    const prev = fromMs(s.ms() - 600_000) orelse return error.FromMsFailed;
    try std.testing.expectEqualStrings("20260712-004000", prev.slice());
    // across a day boundary
    var midnight: Stamp = undefined;
    @memcpy(&midnight.text, "20260801-000000");
    const before = fromMs(midnight.ms() - 600_000) orelse return error.FromMsFailed;
    try std.testing.expectEqualStrings("20260731-235000", before.slice());
    const epoch = fromMs(0) orelse return error.FromMsFailed;
    try std.testing.expectEqualStrings("19700101-000000", epoch.slice());
    try std.testing.expect(fromMs(-1) == null);
}

test "frame ids" {
    try std.testing.expectEqualStrings("20260714-174000", stampOfId("alaska_20260714-174000"));
    try std.testing.expectEqualStrings("20260714-174000", stampOfId("20260714-174000"));
    try std.testing.expect(validId("20260714-174000"));
    try std.testing.expect(validId("alaska_20260714-174000"));
    try std.testing.expect(!validId("manifest"));
    try std.testing.expect(!validId("Alaska_20260714-174000"));
    try std.testing.expect(!validId("20260714-17400"));
}

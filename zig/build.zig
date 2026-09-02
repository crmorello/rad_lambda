const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // GDAL location — homebrew by default; override for docker/linux:
    //   zig build -Dgdal-include=/usr/include/gdal -Dgdal-lib=/usr/lib/...
    const gdal_include = b.option([]const u8, "gdal-include", "GDAL include dir") orelse "/opt/homebrew/include";
    const gdal_lib = b.option([]const u8, "gdal-lib", "GDAL library dir") orelse "/opt/homebrew/lib";
    // H3 (obs ingest): the dir holding h3api.h — brew nests it under h3/,
    // Debian's libh3-dev puts it straight in /usr/include.
    const h3_include = b.option([]const u8, "h3-include", "H3 include dir (contains h3api.h)") orelse "/opt/homebrew/include/h3";
    const h3_lib = b.option([]const u8, "h3-lib", "H3 library dir") orelse "/opt/homebrew/lib";

    const radcore = b.dependency("radcore", .{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "radcore", .module = radcore.module("radcore") },
        },
    });
    mod.addIncludePath(.{ .cwd_relative = gdal_include });
    mod.addLibraryPath(.{ .cwd_relative = gdal_lib });
    mod.linkSystemLibrary("gdal", .{});
    mod.addIncludePath(.{ .cwd_relative = h3_include });
    mod.addLibraryPath(.{ .cwd_relative = h3_lib });
    mod.linkSystemLibrary("h3", .{});

    const exe = b.addExecutable(.{ .name = "rad_lambda", .root_module = mod });
    b.installArtifact(exe);

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);
}

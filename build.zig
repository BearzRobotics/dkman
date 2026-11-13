//! dkman build script. `zig build` builds the program, `zig build test` runs the tests.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    options.addOption([]const u8, "version", @import("build.zig.zon").version);

    const md_dep = b.dependency("md", .{ .target = target, .optimize = optimize });

    const gtroff_dep = b.dependency("gtroff", .{ .target = target, .optimize = optimize });

    // The library: `b.dependency("dkman", .{}).module("dkman")`. It brings md
    // and gtroff along, so a consumer needs no other imports for rendering.
    const lib = b.addModule("dkman", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "md", .module = md_dep.module("md") },
            .{ .name = "gtroff", .module = gtroff_dep.module("gtroff") },
        },
    });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = options.createModule() },
            .{ .name = "md", .module = md_dep.module("md") },
            .{ .name = "gtroff", .module = gtroff_dep.module("gtroff") },
        },
    });

    const exe = b.addExecutable(.{ .name = "dkman", .root_module = mod });
    b.installArtifact(exe);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = lib })).step);
    const unit = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(unit).step);
}

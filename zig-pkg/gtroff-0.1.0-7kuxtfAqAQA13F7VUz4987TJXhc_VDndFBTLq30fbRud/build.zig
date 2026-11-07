//! gtroff-zig build script. `zig build test` runs the tests.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const md_dep = b.dependency("md", .{ .target = target, .optimize = optimize });

    // The library module, importable by consumers as @import("gtroff").
    const mod = b.addModule("gtroff", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "md", .module = md_dep.module("md") }},
    });

    const test_step = b.step("test", "Run unit tests");
    const unit = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(unit).step);

    // Optional, experimental C interface (include/gtroff.h): `zig build c-api`
    // installs libgtroff.a, libgtroff.so and gtroff.h. The native module does not use it.
    const capi_mod = b.createModule(.{
        .root_source_file = b.path("src/capi.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "gtroff", .module = mod }},
    });
    const static_lib = b.addLibrary(.{ .name = "gtroff", .linkage = .static, .root_module = capi_mod });
    const shared_lib = b.addLibrary(.{ .name = "gtroff", .linkage = .dynamic, .root_module = capi_mod });
    const c_api_step = b.step("c-api", "Build the experimental C library and header");
    c_api_step.dependOn(&b.addInstallArtifact(static_lib, .{}).step);
    c_api_step.dependOn(&b.addInstallArtifact(shared_lib, .{}).step);
    c_api_step.dependOn(&b.addInstallFileWithDir(b.path("include/gtroff.h"), .header, "gtroff.h").step);

    // A C program that uses the static library: part of `zig build test`.
    const smoke = b.addExecutable(.{
        .name = "c-smoke",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    smoke.root_module.addCSourceFile(.{ .file = b.path("test/c/smoke.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra" } });
    smoke.root_module.addIncludePath(b.path("include"));
    smoke.root_module.linkLibrary(static_lib);
    test_step.dependOn(&b.addRunArtifact(smoke).step);
}

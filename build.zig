//! dkman build script. `zig build` builds the program, `zig build test` runs the tests.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    options.addOption([]const u8, "version", @import("build.zig.zon").version);

    const md_dep = b.dependency("md", .{ .target = target, .optimize = optimize });

    const regex_dep = b.dependency("regex", .{ .target = target, .optimize = optimize });

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
            .{ .name = "regex", .module = regex_dep.module("regex") },
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
            .{ .name = "regex", .module = regex_dep.module("regex") },
        },
    });

    const exe = b.addExecutable(.{ .name = "dkman", .root_module = mod });
    b.installArtifact(exe);

    // `-Dinstall-as-man` also installs the commands man-db has: dkman acts as
    // whatis, apropos, manpath or mandb by the name it is started under. They
    // are copies; a package may make them symbolic links to dkman.
    if (b.option(bool, "install-as-man", "Also install man, whatis, apropos, manpath and mandb") orelse false) {
        for ([_][]const u8{ "man", "whatis", "apropos", "manpath", "mandb" }) |name| {
            b.getInstallStep().dependOn(&b.addInstallArtifact(exe, .{ .dest_sub_path = name }).step);
        }
    }

    // The manual page (Markdown: dkman reads it), and shell completions.
    b.installFile("docs/manpages/dkman.1.md", "share/man/man1/dkman.1.md");
    b.installFile("completions/dkman.bash", "share/bash-completion/completions/dkman");
    b.installFile("completions/_dkman", "share/zsh/site-functions/_dkman");
    b.installFile("completions/dkman.fish", "share/fish/vendor_completions.d/dkman.fish");

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = lib })).step);
    const unit = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(unit).step);
}

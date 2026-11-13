//! Showing text through the user's pager.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Splits a pager command such as `less -R` into words. There is no shell: no
/// quoting, no expansion. Slices are borrowed from `command`.
pub fn splitCommand(arena: Allocator, command: []const u8) Allocator.Error![]const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, command, " \t");
    while (it.next()) |w| try words.append(arena, w);
    return words.items;
}

/// `less` without an option that passes colors through gets `-R`, so the
/// styles of a page are not shown as escape garbage.
pub fn withColors(arena: Allocator, argv: []const []const u8) Allocator.Error![]const []const u8 {
    if (argv.len == 0 or !std.mem.eql(u8, std.fs.path.basename(argv[0]), "less")) return argv;
    for (argv[1..]) |a| {
        if (a.len > 1 and a[0] == '-' and a[1] != '-' and std.mem.findAny(u8, a, "Rr") != null) return argv;
        if (std.mem.eql(u8, a, "--RAW-CONTROL-CHARS") or std.mem.eql(u8, a, "--raw-control-chars")) return argv;
    }
    const out = try arena.alloc([]const u8, argv.len + 1);
    @memcpy(out[0..argv.len], argv);
    out[argv.len] = "-R";
    return out;
}

/// Writes `text` to stdout.
pub fn writeStdout(io: Io, text: []const u8) !void {
    try Io.File.stdout().writeStreamingAll(io, text);
}

/// Pipes `text` through the pager command. If the pager cannot be started the
/// text goes straight to stdout, so a missing `less` never loses the page.
pub fn show(gpa: Allocator, io: Io, command: []const u8, text: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const argv = try splitCommand(arena_state.allocator(), command);
    if (argv.len == 0) return writeStdout(io, text);
    const run = try withColors(arena_state.allocator(), argv);

    var child = std.process.spawn(io, .{ .argv = run, .stdin = .pipe }) catch return writeStdout(io, text);
    var stdin = child.stdin.?;
    child.stdin = null;
    // A pager the user quits early closes the pipe; that is not an error.
    stdin.writeStreamingAll(io, text) catch {};
    stdin.close(io);
    _ = try child.wait(io);
}

test "splitCommand" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const w = try splitCommand(arena_state.allocator(), "  less   -R -F ");
    try std.testing.expectEqual(@as(usize, 3), w.len);
    try std.testing.expectEqualStrings("-R", w[1]);
    try std.testing.expectEqual(@as(usize, 0), (try splitCommand(arena_state.allocator(), "  ")).len);
}

test "withColors adds -R to a bare less only" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqual(@as(usize, 2), (try withColors(a, &.{"less"})).len);
    try std.testing.expectEqual(@as(usize, 2), (try withColors(a, &.{ "/usr/bin/less", "-R" })).len);
    try std.testing.expectEqual(@as(usize, 2), (try withColors(a, &.{ "less", "-FRX" })).len);
    try std.testing.expectEqual(@as(usize, 1), (try withColors(a, &.{"most"})).len);
}

//! Listing pages and choosing one with fzf.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const paths = @import("paths.zig");

/// Lines for fzf: `name(section)<TAB>path`, sorted by name.
pub fn menuText(gpa: Allocator, pages: []paths.Page) Allocator.Error![]u8 {
    std.mem.sort(paths.Page, pages, {}, byName);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (pages) |p| {
        try out.print(gpa, "{s}({s})\t{s}\n", .{ p.name, p.section, p.path });
    }
    return out.toOwnedSlice(gpa);
}

fn byName(_: void, a: paths.Page, b: paths.Page) bool {
    const c = std.mem.order(u8, a.name, b.name);
    if (c != .eq) return c == .lt;
    return std.mem.lessThan(u8, a.section, b.section);
}

/// The path part of an fzf result line, or null for an empty or malformed one.
pub fn pathFromLine(line: []const u8) ?[]const u8 {
    const tab = std.mem.indexOfScalar(u8, line, '\t') orelse return null;
    const p = std.mem.trimEnd(u8, line[tab + 1 ..], "\r\n");
    return if (p.len == 0) null else p;
}

pub const PickError = error{FzfNotFound} || Allocator.Error || Io.File.Reader.Error || std.process.Child.WaitError;

/// Runs fzf over `menu`. `self_exe` is used for the preview pane. Returns the
/// chosen path (owned by the caller) or null when the user cancels.
pub fn pick(gpa: Allocator, io: Io, menu: []const u8, self_exe: []const u8, query: ?[]const u8) PickError!?[]u8 {
    var preview: std.ArrayList(u8) = .empty;
    defer preview.deinit(gpa);
    try preview.print(gpa, "{s} --no-pager -l {{2}}", .{self_exe});

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "fzf", "--delimiter", "\t", "--with-nth", "1", "--preview", preview.items });
    if (query) |q| try argv.appendSlice(gpa, &.{ "--query", q });

    var child = std.process.spawn(io, .{ .argv = argv.items, .stdin = .pipe, .stdout = .pipe }) catch return error.FzfNotFound;
    var stdin = child.stdin.?;
    child.stdin = null;
    stdin.writeStreamingAll(io, menu) catch {};
    stdin.close(io);

    var buf: [1024]u8 = undefined;
    var reader = child.stdout.?.reader(io, &buf);
    const line = reader.interface.allocRemaining(gpa, .limited(1 << 20)) catch "";
    defer if (line.len > 0) gpa.free(line);
    _ = try child.wait(io);
    const chosen = pathFromLine(std.mem.trim(u8, line, "\n")) orelse return null;
    return try gpa.dupe(u8, chosen);
}

test "menu lines and result parsing" {
    const t = std.testing;
    var pages = [_]paths.Page{
        .{ .name = "zed", .section = "1", .path = "/m/man1/zed.1", .dir_index = 0 },
        .{ .name = "abc", .section = "3", .path = "/m/man3/abc.3.gz", .dir_index = 0 },
    };
    const m = try menuText(t.allocator, &pages);
    defer t.allocator.free(m);
    try t.expectEqualStrings("abc(3)\t/m/man3/abc.3.gz\nzed(1)\t/m/man1/zed.1\n", m);
    try t.expectEqualStrings("/m/man3/abc.3.gz", pathFromLine("abc(3)\t/m/man3/abc.3.gz\n").?);
    try t.expect(pathFromLine("") == null);
    try t.expect(pathFromLine("no tab") == null);
}

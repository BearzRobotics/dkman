//! Listing pages in a stable order.

const std = @import("std");
const Allocator = std.mem.Allocator;
const paths = @import("paths.zig");

/// Sorts by name, then section.
pub fn sortByName(pages: []paths.Page) void {
    std.mem.sort(paths.Page, pages, {}, byName);
}

/// Lines `name(section)<TAB>path`, sorted by name.
pub fn menuText(gpa: Allocator, pages: []paths.Page) Allocator.Error![]u8 {
    sortByName(pages);
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

test "menu lines" {
    const t = std.testing;
    var pages = [_]paths.Page{
        .{ .name = "zed", .section = "1", .path = "/m/man1/zed.1", .dir_index = 0 },
        .{ .name = "abc", .section = "3", .path = "/m/man3/abc.3.gz", .dir_index = 0 },
    };
    const m = try menuText(t.allocator, &pages);
    defer t.allocator.free(m);
    try t.expectEqualStrings("abc(3)\t/m/man3/abc.3.gz\nzed(1)\t/m/man1/zed.1\n", m);
}

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

/// Edit distance between two names ignoring ASCII case, where swapping two
/// neighbouring letters costs one (`pritnf`), or null when it would exceed
/// `limit`. Names longer than 64 bytes are never similar.
fn distance(a: []const u8, b: []const u8, limit: usize) ?usize {
    if (a.len > 64 or b.len > 64) return null;
    if (@max(a.len, b.len) - @min(a.len, b.len) > limit) return null;
    var older: [65]usize = undefined;
    var prev: [65]usize = undefined;
    var cur: [65]usize = undefined;
    for (0..b.len + 1) |j| prev[j] = j;
    for (a, 0..) |ca, i| {
        cur[0] = i + 1;
        for (b, 0..) |cb, j| {
            const lca = std.ascii.toLower(ca);
            const lcb = std.ascii.toLower(cb);
            const cost: usize = if (lca == lcb) 0 else 1;
            cur[j + 1] = @min(@min(prev[j + 1] + 1, cur[j] + 1), prev[j] + cost);
            if (i > 0 and j > 0 and lca == std.ascii.toLower(b[j - 1]) and std.ascii.toLower(a[i - 1]) == lcb) {
                cur[j + 1] = @min(cur[j + 1], older[j - 1] + 1);
            }
        }
        @memcpy(older[0 .. b.len + 1], prev[0 .. b.len + 1]);
        @memcpy(prev[0 .. b.len + 1], cur[0 .. b.len + 1]);
    }
    return if (prev[b.len] <= limit) prev[b.len] else null;
}

/// Up to `max` page names that look like `wanted`, best first: names that
/// start with it (`prin` for `printf`) and names a typo or two away
/// (`pritnf`). Each name once.
pub fn suggest(arena: Allocator, pages: []const paths.Page, wanted: []const u8, max: usize) Allocator.Error![]const []const u8 {
    const Cand = struct { name: []const u8, rank: usize };
    var cands: std.ArrayList(Cand) = .empty;
    // Short names are close to too many others; two letters get no guess.
    const limit: usize = if (wanted.len <= 2) 0 else if (wanted.len <= 4) 1 else 2;
    for (pages) |p| {
        // The page exists: it was filtered out (section, extension), not misspelled.
        if (std.ascii.eqlIgnoreCase(p.name, wanted)) return &.{};
        const rank: usize = if (distance(wanted, p.name, limit)) |d|
            d
        else if (wanted.len >= 3 and std.ascii.startsWithIgnoreCase(p.name, wanted))
            limit + 1
        else
            continue;
        var seen = false;
        for (cands.items) |c| if (std.mem.eql(u8, c.name, p.name)) {
            seen = true;
        };
        if (!seen) try cands.append(arena, .{ .name = p.name, .rank = rank });
    }
    std.mem.sort(Cand, cands.items, {}, struct {
        fn less(_: void, x: Cand, y: Cand) bool {
            if (x.rank != y.rank) return x.rank < y.rank;
            if (x.name.len != y.name.len) return x.name.len < y.name.len;
            return std.mem.lessThan(u8, x.name, y.name);
        }
    }.less);
    // Only the closest: a name one typo away hides those two typos away.
    var n: usize = 0;
    while (n < cands.items.len and n < max and cands.items[n].rank == cands.items[0].rank) n += 1;
    const out = try arena.alloc([]const u8, n);
    for (out, cands.items[0..n]) |*o, c| o.* = c.name;
    return out;
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

test "suggestions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const pages = [_]paths.Page{
        .{ .name = "printf", .section = "1", .path = "/a/printf.1", .dir_index = 0 },
        .{ .name = "printf", .section = "3", .path = "/a/printf.3", .dir_index = 0 },
        .{ .name = "sprintf", .section = "3", .path = "/a/sprintf.3", .dir_index = 0 },
        .{ .name = "zzzzzz", .section = "1", .path = "/a/z.1", .dir_index = 0 },
        .{ .name = "ls", .section = "1", .path = "/a/ls.1", .dir_index = 0 },
    };
    const typo = try suggest(a, &pages, "pritnf", 5);
    try std.testing.expectEqual(@as(usize, 1), typo.len);
    try std.testing.expectEqualStrings("printf", typo[0]);
    const prefix = try suggest(a, &pages, "prin", 5);
    try std.testing.expectEqualStrings("printf", prefix[0]);
    // A swap is one typo; two-letter names are never guessed at.
    try std.testing.expectEqual(@as(usize, 1), (try suggest(a, &pages, "lss", 5)).len);
    try std.testing.expectEqual(@as(usize, 0), (try suggest(a, &pages, "sl", 5)).len);
    // The page exists, so it is not a typo.
    try std.testing.expectEqual(@as(usize, 0), (try suggest(a, &pages, "PRINTF", 5)).len);
    try std.testing.expectEqual(@as(usize, 0), (try suggest(a, &pages, "qqqqqq", 5)).len);
}

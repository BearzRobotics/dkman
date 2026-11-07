//! Finding manual pages in the traditional places.
//!
//! A manual directory (for example `/usr/share/man`) holds section directories
//! `man1`, `man2`, ..., `man3p`, `mann`, `manl`; a page is a file named
//! `NAME.SECTION` with an optional `.gz` (or `.md`, then optional `.gz`) suffix.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Where pages are looked for when `MANPATH` is not set.
pub const default_dirs = [_][]const u8{
    "/usr/local/man",
    "/usr/local/share/man",
    "/usr/share/man",
    "/usr/man",
};

/// Order in which sections are tried when the user gives none (the order of
/// man-db's default `MANSECT`).
const section_order = "1nl8302549 67";

/// A page found on disk.
pub const Page = struct {
    name: []const u8,
    /// Section as in the file name, for example `3` or `3p`.
    section: []const u8,
    /// Absolute or MANPATH-relative path of the file.
    path: []const u8,
    /// Position of the manual directory in the search list.
    dir_index: usize,
};

/// The manual directories to search: `MANPATH` (colon separated, empty entries
/// mean "the defaults") or the defaults. Slices are borrowed from `manpath`.
pub fn searchDirs(arena: Allocator, manpath: ?[]const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (manpath) |mp| {
        var it = std.mem.splitScalar(u8, mp, ':');
        while (it.next()) |part| {
            if (part.len == 0) {
                try out.appendSlice(arena, &default_dirs);
            } else try out.append(arena, part);
        }
    }
    if (out.items.len == 0) try out.appendSlice(arena, &default_dirs);
    return out.items;
}

/// Splits a file name into page name and section, removing `.gz` and `.md`.
/// Returns null for files that do not look like pages.
pub fn splitFileName(file_name: []const u8) ?struct { name: []const u8, section: []const u8 } {
    var s = file_name;
    if (std.mem.endsWith(u8, s, ".gz")) s = s[0 .. s.len - 3];
    if (std.mem.endsWith(u8, s, ".md")) s = s[0 .. s.len - 3];
    const dot = std.mem.lastIndexOfScalar(u8, s, '.') orelse return null;
    const name = s[0..dot];
    const section = s[dot + 1 ..];
    if (name.len == 0 or section.len == 0 or !std.ascii.isAlphanumeric(section[0])) return null;
    return .{ .name = name, .section = section };
}

/// Rank of a section for choosing between pages: lower is tried first.
fn sectionRank(section: []const u8) usize {
    return std.mem.indexOfScalar(u8, section_order, section[0]) orelse section_order.len;
}

/// True when the section directory name (`man3p`) belongs to the requested
/// section (`3` matches `3`, `3p`; `3p` matches only `3p`).
fn sectionMatches(wanted: ?[]const u8, section: []const u8) bool {
    const w = wanted orelse return true;
    return std.mem.startsWith(u8, section, w);
}

/// Calls `visit` for every page below the manual directories. `wanted_name`
/// and `wanted_section` filter when given. Directories that cannot be opened
/// are skipped: a missing `/usr/man` is normal.
pub fn scan(
    arena: Allocator,
    io: Io,
    dirs: []const []const u8,
    wanted_name: ?[]const u8,
    wanted_section: ?[]const u8,
) Allocator.Error![]Page {
    var pages: std.ArrayList(Page) = .empty;
    for (dirs, 0..) |dir_path, dir_index| {
        var base = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch continue;
        defer base.close(io);
        var sections = base.iterate();
        while (sections.next(io) catch break) |sec_entry| {
            if (sec_entry.kind != .directory and sec_entry.kind != .sym_link) continue;
            if (!std.mem.startsWith(u8, sec_entry.name, "man") or sec_entry.name.len < 4) continue;
            const sec_dir_name = sec_entry.name[3..];
            if (!sectionMatches(wanted_section, sec_dir_name)) continue;
            var sd = base.openDir(io, sec_entry.name, .{ .iterate = true }) catch continue;
            defer sd.close(io);
            var files = sd.iterate();
            while (files.next(io) catch break) |f| {
                if (f.kind != .file and f.kind != .sym_link) continue;
                const parts = splitFileName(f.name) orelse continue;
                if (wanted_name) |w| if (!std.mem.eql(u8, w, parts.name)) continue;
                try pages.append(arena, .{
                    .name = try arena.dupe(u8, parts.name),
                    .section = try arena.dupe(u8, parts.section),
                    .path = try std.fs.path.join(arena, &.{ dir_path, sec_entry.name, f.name }),
                    .dir_index = dir_index,
                });
            }
        }
    }
    return pages.items;
}

fn lessThan(_: void, a: Page, b: Page) bool {
    const ra = sectionRank(a.section);
    const rb = sectionRank(b.section);
    if (ra != rb) return ra < rb;
    if (a.dir_index != b.dir_index) return a.dir_index < b.dir_index;
    return std.mem.lessThan(u8, a.path, b.path);
}

/// Sorts pages in the order they are preferred by `man NAME`.
pub fn sortByPreference(pages: []Page) void {
    std.mem.sort(Page, pages, {}, lessThan);
}

/// The page `man NAME` (or `man SECTION NAME`) would show, or null.
pub fn find(arena: Allocator, io: Io, dirs: []const []const u8, name: []const u8, section: ?[]const u8) Allocator.Error!?Page {
    const pages = try scan(arena, io, dirs, name, section);
    if (pages.len == 0) return null;
    sortByPreference(pages);
    return pages[0];
}

/// If the page is only a `.so FILE` redirect (comments and blank lines aside),
/// the FILE it names.
pub fn soTarget(content: []const u8) ?[]const u8 {
    var target: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t\r");
        if (l.len == 0 or std.mem.startsWith(u8, l, ".\\\"") or std.mem.startsWith(u8, l, "'\\\"")) continue;
        if (target != null or !std.mem.startsWith(u8, l, ".so")) return null;
        const arg = std.mem.trim(u8, l[3..], " \t");
        if (arg.len == 0 or std.mem.indexOfAny(u8, arg, " \t") != null) return null;
        target = arg;
    }
    return target;
}

/// Finds the file a `.so` redirect names. The path is relative to a manual
/// directory (`man1/systemd.1`); `.gz` is tried too. Paths that climb out of
/// the directory (`..`) or are absolute are refused.
pub fn resolveSo(arena: Allocator, io: Io, dirs: []const []const u8, target: []const u8) Allocator.Error!?[]const u8 {
    if (target.len == 0 or target[0] == '/' or std.mem.find(u8, target, "..") != null) return null;
    for (dirs) |d| {
        for ([_][]const u8{ "", ".gz" }) |suffix| {
            const path = try std.fmt.allocPrint(arena, "{s}/{s}{s}", .{ d, target, suffix });
            Io.Dir.cwd().access(io, path, .{}) catch continue;
            return path;
        }
    }
    return null;
}

test "soTarget" {
    const t = std.testing;
    try t.expectEqualStrings("man1/systemd.1", soTarget(".so man1/systemd.1\n").?);
    try t.expectEqualStrings("man3/x.3", soTarget(".\\\" note\n\n.so man3/x.3\n").?);
    try t.expect(soTarget(".TH A 1\n.so man1/x.1\n") == null);
    try t.expect(soTarget(".so a.1\n.so b.1\n") == null);
    try t.expect(soTarget("text\n") == null);
    try t.expect(soTarget("") == null);
}

test "splitFileName" {
    const t = std.testing;
    const a = splitFileName("printf.3p.gz").?;
    try t.expectEqualStrings("printf", a.name);
    try t.expectEqualStrings("3p", a.section);
    const b = splitFileName("dkman.1.md").?;
    try t.expectEqualStrings("dkman", b.name);
    try t.expectEqualStrings("1", b.section);
    const c = splitFileName("a.b.c.5").?;
    try t.expectEqualStrings("a.b.c", c.name);
    try t.expect(splitFileName("README") == null);
    try t.expect(splitFileName(".1") == null);
}

test "searchDirs uses MANPATH and expands empty entries to the defaults" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const d1 = try searchDirs(a, "/x:/y");
    try std.testing.expectEqual(@as(usize, 2), d1.len);
    const d2 = try searchDirs(a, "/x::/y");
    try std.testing.expectEqual(2 + default_dirs.len, d2.len);
    const d3 = try searchDirs(a, null);
    try std.testing.expectEqual(default_dirs.len, d3.len);
}

test "find picks the preferred section and honours a requested one" {
    const t = std.testing;
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "m/man1");
    try tmp.dir.createDirPath(io, "m/man3");
    try tmp.dir.createDirPath(io, "m/man3p");
    try tmp.dir.writeFile(io, .{ .sub_path = "m/man1/foo.1", .data = ".TH FOO 1\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "m/man3/foo.3.gz", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "m/man3p/foo.3p", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "m/man1/other.1.md", .data = "# x\n" });

    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root = try tmp.dir.realPathFileAlloc(io, "m", a);
    const dirs = [_][]const u8{ root, "/nonexistent-dkman-dir" };

    const any = (try find(a, io, &dirs, "foo", null)).?;
    try t.expectEqualStrings("1", any.section);
    const three = (try find(a, io, &dirs, "foo", "3")).?;
    try t.expectEqualStrings("3", three.section);
    const posix = (try find(a, io, &dirs, "foo", "3p")).?;
    try t.expectEqualStrings("3p", posix.section);
    try t.expect((try find(a, io, &dirs, "missing", null)) == null);
    const md_page = (try find(a, io, &dirs, "other", null)).?;
    try t.expect(std.mem.endsWith(u8, md_page.path, "other.1.md"));
}

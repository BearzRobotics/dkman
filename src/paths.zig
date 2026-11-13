//! Finding manual pages in the traditional places.
//!
//! A manual directory (for example `/usr/share/man`) holds section directories
//! `man1`, `man2`, ..., `man3p`, `mann`, `manl`; a page is a file named
//! `NAME.SECTION` with an optional compression suffix (`.gz`, `.xz`, `.zst`, `.bz2`, `.lzma`), or `.md` then an optional compression suffix.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const format = @import("format.zig");

/// Where pages are looked for when `MANPATH` is not set.
pub const default_dirs = [_][]const u8{
    "/usr/local/man",
    "/usr/local/share/man",
    "/usr/share/man",
    "/usr/man",
};

/// Order in which sections are tried when the user gives none (the order of
/// man-db's default `SECTION`).
pub const default_sections = [_][]const u8{ "1", "n", "l", "8", "3", "0", "2", "5", "4", "9", "6", "7" };

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
/// mean "the usual ones", `usual`) or, when it is not set, `usual`. Slices are
/// borrowed from `manpath` and `usual`.
pub fn searchDirs(arena: Allocator, manpath: ?[]const u8, usual: []const []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (manpath) |mp| {
        var it = std.mem.splitScalar(u8, mp, ':');
        while (it.next()) |part| {
            if (part.len == 0) {
                try out.appendSlice(arena, usual);
            } else try out.append(arena, part);
        }
    }
    if (out.items.len == 0) try out.appendSlice(arena, usual);
    return out.items;
}

/// Splits a file name into page name and section, removing a compression suffix and `.md`.
/// Returns null for files that do not look like pages.
pub fn splitFileName(file_name: []const u8) ?struct { name: []const u8, section: []const u8 } {
    var s = file_name;
    s = format.withoutCompression(s);
    if (std.mem.endsWith(u8, s, ".md")) s = s[0 .. s.len - 3];
    const dot = std.mem.lastIndexOfScalar(u8, s, '.') orelse return null;
    const name = s[0..dot];
    const section = s[dot + 1 ..];
    if (name.len == 0 or section.len == 0 or !std.ascii.isAlphanumeric(section[0])) return null;
    return .{ .name = name, .section = section };
}

/// Rank of a section for choosing between pages: lower is tried first. An
/// entry of `order` matches a section it is a prefix of (`3` also stands for
/// `3p`), the exact entry ranking first; sections not listed come last.
pub fn sectionRank(order: []const []const u8, section: []const u8) usize {
    for (order, 0..) |entry, i| {
        if (entry.len == 0 or !std.mem.startsWith(u8, section, entry)) continue;
        return i * 2 + @intFromBool(section.len > entry.len);
    }
    return order.len * 2;
}

/// True when the section directory name (`man3p`) belongs to the requested
/// section (`3` matches `3`, `3p`; `3p` matches only `3p`).
fn sectionMatches(wanted: ?[]const u8, section: []const u8) bool {
    const w = wanted orelse return true;
    return std.mem.startsWith(u8, section, w);
}

fn sameName(wanted: []const u8, name: []const u8, ignore_case: bool) bool {
    return if (ignore_case) std.ascii.eqlIgnoreCase(wanted, name) else std.mem.eql(u8, wanted, name);
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
    ignore_case: bool,
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
                if (wanted_name) |w| if (!sameName(w, parts.name, ignore_case)) continue;
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

const Ordering = struct {
    order: []const []const u8,

    fn lessThan(o: Ordering, a: Page, b: Page) bool {
        const ra = sectionRank(o.order, a.section);
        const rb = sectionRank(o.order, b.section);
        if (ra != rb) return ra < rb;
        if (a.dir_index != b.dir_index) return a.dir_index < b.dir_index;
        return std.mem.lessThan(u8, a.path, b.path);
    }
};

/// Sorts pages in the order they are preferred by `man NAME`; `order` is the
/// list of sections to try first to last (`default_sections`, `MANSECT`, ...).
pub fn sortByPreference(pages: []Page, order: []const []const u8) void {
    std.mem.sort(Page, pages, Ordering{ .order = order }, Ordering.lessThan);
}

/// Every page called `name`, most preferred first. `sections` limits the
/// result to those sections (`3` includes `3p`) and also sets the order; when
/// empty every section is considered, tried in `order`. Names are compared
/// ignoring ASCII case when `ignore_case` is set.
pub fn findAll(
    arena: Allocator,
    io: Io,
    dirs: []const []const u8,
    name: []const u8,
    sections: []const []const u8,
    order: []const []const u8,
    ignore_case: bool,
) Allocator.Error![]Page {
    const all = try scan(arena, io, dirs, name, null, ignore_case);
    var kept: std.ArrayList(Page) = .empty;
    for (all) |p| {
        if (sections.len > 0) {
            var ok = false;
            for (sections) |w| {
                if (sectionMatches(w, p.section)) ok = true;
            }
            if (!ok) continue;
        }
        try kept.append(arena, p);
    }
    sortByPreference(kept.items, if (sections.len > 0) sections else order);
    return kept.items;
}

/// The page `man NAME` (or `man SECTION NAME`) would show, or null.
pub fn find(arena: Allocator, io: Io, dirs: []const []const u8, name: []const u8, section: ?[]const u8, order: []const []const u8, ignore_case: bool) Allocator.Error!?Page {
    const wanted: []const []const u8 = if (section) |sec| &.{sec} else &.{};
    const pages = try findAll(arena, io, dirs, name, wanted, order, ignore_case);
    if (pages.len == 0) return null;
    return pages[0];
}

/// Splits `printf(3)` into the name and its section. Anything else is a name.
pub fn splitNameSection(arg: []const u8) struct { name: []const u8, section: ?[]const u8 } {
    if (arg.len > 3 and arg[arg.len - 1] == ')') {
        if (std.mem.lastIndexOfScalar(u8, arg, '(')) |open| {
            const sec = arg[open + 1 .. arg.len - 1];
            if (open > 0 and sec.len > 0 and std.ascii.isAlphanumeric(sec[0])) return .{ .name = arg[0..open], .section = sec };
        }
    }
    return .{ .name = arg, .section = null };
}

// -------------------------------------------------------- manual directories

/// What `/etc/manpath.config` (or `/etc/man_db.conf`) says that dkman uses.
pub const Conf = struct {
    /// `MANDATORY_MANPATH`: always searched.
    mandatory: []const []const u8 = &.{},
    /// `MANPATH_MAP`: a `PATH` directory and the manual directory it implies.
    maps: []const Map = &.{},
    /// `SECTION`: the order sections are tried in.
    sections: []const []const u8 = &.{},

    pub const Map = struct { from: []const u8, to: []const u8 };
};

/// Reads the settings dkman understands; other lines are ignored. Slices are
/// borrowed from `text`.
pub fn parseConf(arena: Allocator, text: []const u8) Allocator.Error!Conf {
    var mandatory: std.ArrayList([]const u8) = .empty;
    var maps: std.ArrayList(Conf.Map) = .empty;
    var sections: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var words = std.mem.tokenizeAny(u8, line, " \t");
        const key = words.next() orelse continue;
        if (std.mem.eql(u8, key, "MANDATORY_MANPATH")) {
            if (words.next()) |d| try mandatory.append(arena, d);
        } else if (std.mem.eql(u8, key, "MANPATH_MAP")) {
            const from = words.next() orelse continue;
            const to = words.next() orelse continue;
            try maps.append(arena, .{ .from = from, .to = to });
        } else if (std.mem.eql(u8, key, "SECTION")) {
            while (words.next()) |w| try sections.append(arena, w);
        }
    }
    return .{ .mandatory = mandatory.items, .maps = maps.items, .sections = sections.items };
}

fn dirExists(io: Io, path: []const u8) bool {
    var d = Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    d.close(io);
    return true;
}

fn addUnique(arena: Allocator, list: *std.ArrayList([]const u8), dir: []const u8) Allocator.Error!void {
    var d = dir;
    while (d.len > 1 and d[d.len - 1] == '/') d = d[0 .. d.len - 1];
    for (list.items) |have| if (std.mem.eql(u8, have, d)) return;
    try list.append(arena, d);
}

/// The manual directories when `MANPATH` is not set, found the way man-db
/// does: every `PATH` directory implies a manual directory (through
/// `MANPATH_MAP`, or `bin`/`sbin` becoming `man` and `share/man` next to it),
/// then the `MANDATORY_MANPATH` entries. Only directories that exist are kept;
/// with nothing found the built-in defaults are used.
pub fn deriveManpath(arena: Allocator, io: Io, path_env: ?[]const u8, conf: Conf) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (path_env) |pe| {
        var it = std.mem.splitScalar(u8, pe, ':');
        while (it.next()) |entry_raw| {
            var entry = entry_raw;
            if (entry.len == 0 or entry[0] != '/') continue;
            while (entry.len > 1 and entry[entry.len - 1] == '/') entry = entry[0 .. entry.len - 1];
            var mapped = false;
            for (conf.maps) |m| {
                if (std.mem.eql(u8, m.from, entry)) {
                    mapped = true;
                    if (dirExists(io, m.to)) try addUnique(arena, &out, m.to);
                }
            }
            if (mapped) continue;
            const base = if (std.mem.endsWith(u8, entry, "/bin")) entry[0 .. entry.len - 4] else if (std.mem.endsWith(u8, entry, "/sbin")) entry[0 .. entry.len - 5] else continue;
            for ([_][]const u8{ "man", "share/man" }) |sub| {
                const cand = try std.fs.path.join(arena, &.{ base, sub });
                if (dirExists(io, cand)) try addUnique(arena, &out, cand);
            }
        }
    }
    for (conf.mandatory) |d| if (dirExists(io, d)) try addUnique(arena, &out, d);
    if (out.items.len == 0) try out.appendSlice(arena, &default_dirs);
    return out.items;
}

/// Adds the locale's directories before each manual directory: for `de_DE.UTF-8`
/// `DIR/de_DE`, then `DIR/de`, then `DIR` itself. `C`, `POSIX` and an empty
/// locale change nothing. Directories that do not exist are harmless: `scan`
/// skips them.
pub fn withLocale(arena: Allocator, dirs: []const []const u8, locale: ?[]const u8) Allocator.Error![]const []const u8 {
    var loc = locale orelse return dirs;
    if (std.mem.findAny(u8, loc, ".@")) |i| loc = loc[0..i];
    if (loc.len == 0 or std.mem.eql(u8, loc, "C") or std.mem.eql(u8, loc, "POSIX")) return dirs;
    const lang = if (std.mem.findScalar(u8, loc, '_')) |i| loc[0..i] else loc;
    var out: std.ArrayList([]const u8) = .empty;
    for (dirs) |d| {
        try out.append(arena, try std.fs.path.join(arena, &.{ d, loc }));
        if (!std.mem.eql(u8, lang, loc)) try out.append(arena, try std.fs.path.join(arena, &.{ d, lang }));
        try out.append(arena, d);
    }
    return out.items;
}

/// Splits a section list (`1:n:3` or `1,n,3`) into its entries.
pub fn parseSections(arena: Allocator, text: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, text, ":, \t");
    while (it.next()) |w| try out.append(arena, w);
    return out.items;
}

/// The file a symbolic link names, followed to the end (at most 8 links), as
/// man-db shows it: `lroundf.3.gz -> lround.3.gz` is `.../lround.3.gz`. A path
/// that is not a link is returned as it is. Only the last component is
/// resolved, so a manual directory that is itself a link keeps its name.
pub fn followLinks(arena: Allocator, io: Io, path: []const u8) Allocator.Error![]const u8 {
    var cur = path;
    for (0..8) |_| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = Io.Dir.cwd().readLink(io, cur, &buf) catch return cur;
        const target = buf[0..n];
        if (std.fs.path.isAbsolute(target)) {
            cur = try arena.dupe(u8, target);
        } else {
            cur = try std.fs.path.join(arena, &.{ std.fs.path.dirname(cur) orelse ".", target });
        }
    }
    return cur;
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
/// directory (`man1/systemd.1`); compression suffixes are tried too. Paths that climb out of
/// the directory (`..`) or are absolute are refused.
pub fn resolveSo(arena: Allocator, io: Io, dirs: []const []const u8, target: []const u8) Allocator.Error!?[]const u8 {
    if (target.len == 0 or target[0] == '/' or std.mem.find(u8, target, "..") != null) return null;
    for (dirs) |d| {
        for ([_][]const u8{ "", ".gz", ".xz", ".zst", ".bz2", ".lzma" }) |suffix| {
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
    const z = splitFileName("ls.1.zst").?;
    try t.expectEqualStrings("ls", z.name);
    try t.expectEqualStrings("1", z.section);
    const c = splitFileName("a.b.c.5").?;
    try t.expectEqualStrings("a.b.c", c.name);
    try t.expect(splitFileName("README") == null);
    try t.expect(splitFileName(".1") == null);
}

test "searchDirs uses MANPATH and expands empty entries to the usual ones" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const d1 = try searchDirs(a, "/x:/y", &default_dirs);
    try std.testing.expectEqual(@as(usize, 2), d1.len);
    const d2 = try searchDirs(a, "/x::/y", &default_dirs);
    try std.testing.expectEqual(2 + default_dirs.len, d2.len);
    const d3 = try searchDirs(a, null, &default_dirs);
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

    const any = (try find(a, io, &dirs, "foo", null, &default_sections, false)).?;
    try t.expectEqualStrings("1", any.section);
    const three = (try find(a, io, &dirs, "foo", "3", &default_sections, false)).?;
    try t.expectEqualStrings("3", three.section);
    const posix = (try find(a, io, &dirs, "foo", "3p", &default_sections, false)).?;
    try t.expectEqualStrings("3p", posix.section);
    try t.expect((try find(a, io, &dirs, "missing", null, &default_sections, false)) == null);
    try t.expect((try find(a, io, &dirs, "FOO", null, &default_sections, false)) == null);
    try t.expectEqualStrings("1", (try find(a, io, &dirs, "FOO", null, &default_sections, true)).?.section);
    const md_page = (try find(a, io, &dirs, "other", null, &default_sections, false)).?;
    try t.expect(std.mem.endsWith(u8, md_page.path, "other.1.md"));
}

test "section ranking and lists" {
    const t = std.testing;
    try t.expect(sectionRank(&default_sections, "1") < sectionRank(&default_sections, "3"));
    try t.expect(sectionRank(&default_sections, "3") < sectionRank(&default_sections, "3p"));
    try t.expect(sectionRank(&default_sections, "3p") < sectionRank(&default_sections, "2"));
    try t.expect(sectionRank(&default_sections, "zz") == default_sections.len * 2);
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const l = try parseSections(arena_state.allocator(), "3:2,n");
    try t.expectEqual(@as(usize, 3), l.len);
    try t.expectEqualStrings("2", l[1]);
}

test "findAll restricts to the given sections and orders by them" {
    const t = std.testing;
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "m/man1");
    try tmp.dir.createDirPath(io, "m/man3");
    try tmp.dir.createDirPath(io, "m/man5");
    try tmp.dir.writeFile(io, .{ .sub_path = "m/man1/foo.1", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "m/man3/foo.3", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "m/man5/foo.5", .data = "x" });
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const dirs = [_][]const u8{try tmp.dir.realPathFileAlloc(io, "m", a)};

    const all = try findAll(a, io, &dirs, "foo", &.{}, &default_sections, false);
    try t.expectEqual(@as(usize, 3), all.len);
    try t.expectEqualStrings("1", all[0].section);
    const some = try findAll(a, io, &dirs, "foo", &.{ "5", "3" }, &default_sections, false);
    try t.expectEqual(@as(usize, 2), some.len);
    try t.expectEqualStrings("5", some[0].section);
}

test "splitNameSection" {
    const t = std.testing;
    const a = splitNameSection("printf(3)");
    try t.expectEqualStrings("printf", a.name);
    try t.expectEqualStrings("3", a.section.?);
    try t.expect(splitNameSection("printf").section == null);
    try t.expect(splitNameSection("(3)").section == null);
    try t.expectEqualStrings("a(b", splitNameSection("a(b").name);
}

test "withLocale puts the locale before each directory" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const out = try withLocale(a, &.{"/m"}, "de_DE.UTF-8");
    try std.testing.expectEqual(@as(usize, 3), out.len);
    try std.testing.expectEqualStrings("/m/de_DE", out[0]);
    try std.testing.expectEqualStrings("/m/de", out[1]);
    try std.testing.expectEqualStrings("/m", out[2]);
    try std.testing.expectEqual(@as(usize, 1), (try withLocale(a, &.{"/m"}, "C")).len);
    try std.testing.expectEqual(@as(usize, 1), (try withLocale(a, &.{"/m"}, null)).len);
    try std.testing.expectEqual(@as(usize, 2), (try withLocale(a, &.{"/m"}, "fr")).len);
}

test "deriveManpath follows PATH, the map and the mandatory list" {
    const t = std.testing;
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "opt/tool/bin");
    try tmp.dir.createDirPath(io, "opt/tool/share/man");
    try tmp.dir.createDirPath(io, "mand");
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const conf_text = try std.fmt.allocPrint(a, "# c\nMANDATORY_MANPATH {s}/mand\nSECTION 1 3\nMANPATH_MAP /nowhere/bin {s}/mand\n", .{ root, root });
    const conf = try parseConf(a, conf_text);
    try t.expectEqual(@as(usize, 1), conf.maps.len);
    try t.expectEqual(@as(usize, 2), conf.sections.len);
    const path_env = try std.fmt.allocPrint(a, "{s}/opt/tool/bin:/nowhere/bin:relative:/x/y", .{root});
    const dirs = try deriveManpath(a, io, path_env, conf);
    try t.expectEqual(@as(usize, 2), dirs.len);
    try t.expect(std.mem.endsWith(u8, dirs[0], "opt/tool/share/man"));
    try t.expect(std.mem.endsWith(u8, dirs[1], "mand"));
    // Nothing found: the built-in defaults.
    const none = try deriveManpath(a, io, null, .{});
    try t.expectEqual(default_dirs.len, none.len);
}

test "followLinks follows a chain of links and leaves plain files alone" {
    const t = std.testing;
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "man1");
    try tmp.dir.writeFile(io, .{ .sub_path = "man1/real.1", .data = "x" });
    try tmp.dir.symLink(io, "real.1", "man1/mid.1", .{});
    try tmp.dir.symLink(io, "mid.1", "man1/top.1", .{});
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const top = try std.fs.path.join(a, &.{ root, "man1", "top.1" });
    const real = try std.fs.path.join(a, &.{ root, "man1", "real.1" });
    try t.expectEqualStrings(real, try followLinks(a, io, top));
    try t.expectEqualStrings(real, try followLinks(a, io, real));
}

//! One-line descriptions of pages (the NAME section), for `-f` (whatis) and
//! `-k` (apropos), and a cache of them so that listing is quick.
//!
//! The index is a text file: a first line `dkman-whatis 1 FINGERPRINT`, then
//! one line `name TAB section TAB path TAB description` per name a page
//! declares. The fingerprint changes when a manual directory is added to or
//! removed from, which is what makes the cache stale.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const paths = @import("paths.zig");
const page_mod = @import("page.zig");
const render = @import("render.zig");

pub const Entry = struct {
    name: []const u8,
    section: []const u8,
    path: []const u8,
    /// Empty when the page has no NAME section to read.
    description: []const u8,
};

/// Names and description of a NAME section's text.
pub const Parsed = struct {
    names: []const []const u8,
    description: []const u8,
};

const name_headings = [_][]const u8{ "NAME", "NOM", "NOMBRE", "NOME", "NAMN", "NAAM", "NAZWA", "NIMI", "NAVN", "NUME", "JMÉNO", "NÉV", "ИМЯ", "НАЗВАНИЕ", "名前", "名称", "名字", "이름", "NAME/NAMEN", "BEZEICHNUNG" };

fn isHeading(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " \t\r");
    if (t.len == 0 or line[0] == ' ' or line[0] == '\t') return false;
    for (name_headings) |h| if (std.ascii.eqlIgnoreCase(t, h)) return true;
    return false;
}

/// The text of the NAME section of rendered plain text: the lines after the
/// `NAME` heading (in a few languages; failing that, the heading after the
/// title line) up to the first blank line or the next heading, joined with
/// single spaces. Null when there is none.
pub fn nameSection(arena: Allocator, text: []const u8) Allocator.Error!?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var found = false;
    var unindented: usize = 0;
    const saved = lines;
    while (lines.next()) |raw| {
        if (isHeading(raw)) {
            found = true;
            break;
        }
    }
    if (!found) {
        // Heading in an unknown language: the second unindented line (the
        // first is the page title).
        lines = saved;
        while (lines.next()) |raw| {
            if (raw.len == 0 or raw[0] == ' ' or raw[0] == '\t') continue;
            unindented += 1;
            if (unindented == 2) {
                found = true;
                break;
            }
        }
    }
    if (!found) return null;
    var out: std.ArrayList(u8) = .empty;
    var started = false;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) {
            if (started) break;
            continue;
        }
        // The next heading: not indented, and shouting.
        if (started and raw[0] != ' ' and raw[0] != '\t' and std.ascii.isUpper(raw[0])) break;
        if (started) try out.append(arena, ' ');
        started = true;
        try out.appendSlice(arena, line);
    }
    if (out.items.len == 0) return null;
    return out.items;
}

/// Roff source up to (not including) the second section heading: the
/// preamble and the first section, which is the NAME section. Rendering only
/// that is much faster than rendering a whole page. Other text is returned
/// unchanged.
pub fn head(bytes: []const u8, fmt: @import("format.zig").Format) []const u8 {
    const macro = switch (fmt) {
        .man => ".SH",
        .mdoc => ".Sh",
        else => return bytes,
    };
    var seen: usize = 0;
    var pos: usize = 0;
    while (pos < bytes.len) {
        const end = std.mem.findScalarPos(u8, bytes, pos, '\n') orelse bytes.len;
        const line = bytes[pos..end];
        if (std.mem.startsWith(u8, line, macro) and (line.len == macro.len or line[macro.len] == ' ' or line[macro.len] == '\t')) {
            seen += 1;
            if (seen == 2) return bytes[0..pos];
        }
        pos = end + 1;
    }
    return bytes;
}

const separators = [_][]const u8{ " - ", " \u{2014} ", " \u{2013} ", " \\- ", " -- " };

/// Splits `ls, dir - list directory contents` into the names and the text
/// after the dash.
pub fn splitNameLine(arena: Allocator, line: []const u8) Allocator.Error!Parsed {
    var cut: ?usize = null;
    var cut_len: usize = 0;
    for (separators) |sep| {
        if (std.mem.find(u8, line, sep)) |i| {
            if (cut == null or i < cut.?) {
                cut = i;
                cut_len = sep.len;
            }
        }
    }
    // No dash: not a "names - description" line; there is nothing to learn.
    if (cut == null) return .{ .names = &.{}, .description = "" };
    const left = line[0..cut.?];
    const desc = if (cut) |i| std.mem.trim(u8, line[i + cut_len ..], " \t") else "";
    var names: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, left, ',');
    while (it.next()) |n| {
        const t = std.mem.trim(u8, n, " \t");
        if (t.len > 0) try names.append(arena, t);
    }
    return .{ .names = names.items, .description = desc };
}

fn fingerprint(io: Io, dirs: []const []const u8) u64 {
    var h = std.hash.Wyhash.init(0x646b6d616e);
    for (dirs) |d| {
        h.update(d);
        var base = Io.Dir.cwd().openDir(io, d, .{ .iterate = true }) catch continue;
        defer base.close(io);
        if (base.stat(io)) |st| h.update(std.mem.asBytes(&st.mtime.nanoseconds)) else |_| {}
        var it = base.iterate();
        while (it.next(io) catch null) |e| {
            if (!std.mem.startsWith(u8, e.name, "man")) continue;
            h.update(e.name);
            if (base.statFile(io, e.name, .{})) |st| h.update(std.mem.asBytes(&st.mtime.nanoseconds)) else |_| {}
        }
    }
    return h.final();
}

/// Reads every page and gathers the names and descriptions. Slow (it renders
/// every page): prefer `load`, which caches. `gpa` owns the result's text.
pub fn build(gpa: Allocator, arena: Allocator, io: Io, dirs: []const []const u8) Allocator.Error![]Entry {
    const pages = try paths.scan(arena, io, dirs, null, null);
    var out: std.ArrayList(Entry) = .empty;
    for (pages) |pg| {
        var scratch_state = std.heap.ArenaAllocator.init(gpa);
        defer scratch_state.deinit();
        const scratch = scratch_state.allocator();
        var parsed: Parsed = .{ .names = &.{}, .description = "" };
        if (page_mod.load(gpa, scratch, io, dirs, pg.path)) |loaded| {
            defer loaded.deinit(gpa);
            if (render.render(gpa, loaded.format, head(loaded.bytes, loaded.format), .{ .width = 0 })) |text| {
                defer gpa.free(text);
                if (try nameSection(scratch, text)) |line| parsed = try splitNameLine(scratch, line);
            } else |_| {}
        } else |_| {}
        var has_own_name = false;
        for (parsed.names) |n| {
            if (std.mem.eql(u8, n, pg.name)) has_own_name = true;
            try out.append(arena, .{
                .name = try arena.dupe(u8, n),
                .section = pg.section,
                .path = pg.path,
                .description = try arena.dupe(u8, parsed.description),
            });
        }
        if (!has_own_name) try out.append(arena, .{
            .name = pg.name,
            .section = pg.section,
            .path = pg.path,
            .description = try arena.dupe(u8, parsed.description),
        });
    }
    std.mem.sort(Entry, out.items, {}, entryLess);
    return dedupe(out.items);
}

/// Drops entries that repeat the previous one's name, section and text: the
/// pages that only redirect (`.so`) to another page say the same.
fn dedupe(sorted: []Entry) []Entry {
    var n: usize = 0;
    for (sorted) |e| {
        if (n > 0) {
            const p = sorted[n - 1];
            if (std.mem.eql(u8, p.name, e.name) and std.mem.eql(u8, p.section, e.section) and std.mem.eql(u8, p.description, e.description)) continue;
        }
        sorted[n] = e;
        n += 1;
    }
    return sorted[0..n];
}

fn entryLess(_: void, a: Entry, b: Entry) bool {
    const c = std.mem.order(u8, a.name, b.name);
    if (c != .eq) return c == .lt;
    const s = std.mem.order(u8, a.section, b.section);
    if (s != .eq) return s == .lt;
    return std.mem.lessThan(u8, a.path, b.path);
}

fn serialize(arena: Allocator, entries: []const Entry, print: u64) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "dkman-whatis 1 {x}\n", .{print});
    for (entries) |e| {
        try out.print(arena, "{s}\t{s}\t{s}\t{s}\n", .{ e.name, e.section, e.path, e.description });
    }
    return out.items;
}

/// Parses an index file's text. Slices are borrowed from `text`. Null when the
/// header is wrong or the fingerprint differs from `print`.
pub fn parseIndex(arena: Allocator, text: []const u8, print: u64) Allocator.Error!?[]Entry {
    var lines = std.mem.splitScalar(u8, text, '\n');
    const first = lines.next() orelse return null;
    var words = std.mem.splitScalar(u8, first, ' ');
    if (!std.mem.eql(u8, words.next() orelse "", "dkman-whatis")) return null;
    if (!std.mem.eql(u8, words.next() orelse "", "1")) return null;
    const got = std.fmt.parseInt(u64, words.next() orelse "", 16) catch return null;
    if (got != print) return null;
    var out: std.ArrayList(Entry) = .empty;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var f = std.mem.splitScalar(u8, line, '\t');
        const name = f.next() orelse continue;
        const section = f.next() orelse continue;
        const path = f.next() orelse continue;
        try out.append(arena, .{ .name = name, .section = section, .path = path, .description = f.rest() });
    }
    return out.items;
}

/// The index for `dirs`: read from `cache_file` when it is current, otherwise
/// built and (if `cache_file` is given) written there. `force` rebuilds. `notice`
/// is written to standard error before a slow build starts.
pub fn load(gpa: Allocator, arena: Allocator, io: Io, dirs: []const []const u8, cache_file: ?[]const u8, force: bool, notice: ?[]const u8) Allocator.Error![]Entry {
    const print = fingerprint(io, dirs);
    if (cache_file) |cf| if (!force) {
        if (Io.Dir.cwd().readFileAlloc(io, cf, arena, .limited(256 * 1024 * 1024))) |text| {
            if (try parseIndex(arena, text, print)) |entries| return entries;
        } else |_| {}
    };
    if (notice) |msg| Io.File.stderr().writeStreamingAll(io, msg) catch {};
    const entries = try build(gpa, arena, io, dirs);
    if (cache_file) |cf| {
        if (std.fs.path.dirname(cf)) |d| Io.Dir.cwd().createDirPath(io, d) catch return entries;
        const data = try serialize(arena, entries, print);
        const tmp = try std.fmt.allocPrint(arena, "{s}.tmp{x}", .{ cf, print });
        if (Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = data })) {
            Io.Dir.rename(Io.Dir.cwd(), tmp, Io.Dir.cwd(), cf, io) catch Io.Dir.cwd().deleteFile(io, tmp) catch {};
        } else |_| {}
    }
    return entries;
}

/// `name (section)     - description`, the way whatis(1) prints it.
pub fn formatEntry(gpa: Allocator, e: Entry, name_width: usize) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.print(gpa, "{s} ({s})", .{ e.name, e.section });
    while (out.items.len < name_width) try out.append(gpa, ' ');
    try out.appendSlice(gpa, " - ");
    try out.appendSlice(gpa, if (e.description.len > 0) e.description else "(unknown subject)");
    try out.append(gpa, '\n');
    return out.toOwnedSlice(gpa);
}

/// The listing for `-f`/`-k`: the lines for `entries`, with the dashes lined up.
pub fn listing(gpa: Allocator, entries: []const Entry) Allocator.Error![]u8 {
    var width: usize = 0;
    for (entries) |e| width = @max(width, e.name.len + e.section.len + 3);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (entries) |e| {
        const line = try formatEntry(gpa, e, @min(width, 40));
        defer gpa.free(line);
        try out.appendSlice(gpa, line);
    }
    return out.toOwnedSlice(gpa);
}

/// Entries whose name is exactly `name` (whatis).
pub fn exact(arena: Allocator, entries: []const Entry, name: []const u8, sections: []const []const u8) Allocator.Error![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    for (entries) |e| {
        if (!std.mem.eql(u8, e.name, name)) continue;
        if (!inSections(e, sections)) continue;
        try out.append(arena, e);
    }
    return out.items;
}

/// Entries whose name or description contains a keyword, ignoring case
/// (apropos). With `all`, every keyword must be found; otherwise any one.
pub fn keywords(arena: Allocator, entries: []const Entry, words: []const []const u8, all: bool, sections: []const []const u8) Allocator.Error![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    for (entries) |e| {
        if (!inSections(e, sections)) continue;
        var hits: usize = 0;
        for (words) |w| {
            if (std.ascii.findIgnoreCase(e.name, w) != null or std.ascii.findIgnoreCase(e.description, w) != null) hits += 1;
        }
        if (if (all) hits == words.len else hits > 0) try out.append(arena, e);
    }
    return out.items;
}

fn inSections(e: Entry, sections: []const []const u8) bool {
    if (sections.len == 0) return true;
    for (sections) |s| if (std.mem.startsWith(u8, e.section, s)) return true;
    return false;
}

test "nameSection reads the paragraph after the heading" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const text = "LS(1)\n\nNAME\n\n       ls - list directory\n       contents\n\nSYNOPSIS\n\n       ls\n";
    try std.testing.expectEqualStrings("ls - list directory contents", (try nameSection(a, text)).?);
    try std.testing.expect((try nameSection(a, "no heading here\n")) == null);
    // Without the blank line after the paragraph, the next heading ends it.
    try std.testing.expectEqualStrings("x - y", (try nameSection(a, "NAME\n  x - y\nSYNOPSIS\n  x\n")).?);
}

test "splitNameLine" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const p = try splitNameLine(a, "ls, dir, vdir - list directory contents");
    try std.testing.expectEqual(@as(usize, 3), p.names.len);
    try std.testing.expectEqualStrings("dir", p.names[1]);
    try std.testing.expectEqualStrings("list directory contents", p.description);
    const m = try splitNameLine(a, "a \u{2014} a thing");
    try std.testing.expectEqualStrings("a", m.names[0]);
    try std.testing.expectEqualStrings("a thing", m.description);
    const n = try splitNameLine(a, "lonely");
    try std.testing.expectEqualStrings("", n.description);
    try std.testing.expectEqual(@as(usize, 0), n.names.len);
}

test "index round trip and search" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const entries = [_]Entry{
        .{ .name = "ls", .section = "1", .path = "/m/man1/ls.1", .description = "list directory contents" },
        .{ .name = "open", .section = "2", .path = "/m/man2/open.2", .description = "open a file" },
    };
    const text = try serialize(a, &entries, 0xabc);
    try t.expect((try parseIndex(a, text, 0xabd)) == null);
    const back = (try parseIndex(a, text, 0xabc)).?;
    try t.expectEqual(@as(usize, 2), back.len);
    try t.expectEqualStrings("open a file", back[1].description);

    try t.expectEqual(@as(usize, 1), (try exact(a, back, "ls", &.{})).len);
    try t.expectEqual(@as(usize, 0), (try exact(a, back, "ls", &.{"2"})).len);
    try t.expectEqual(@as(usize, 1), (try keywords(a, back, &.{ "FILE", "zzz" }, false, &.{})).len);
    try t.expectEqual(@as(usize, 0), (try keywords(a, back, &.{ "file", "zzz" }, true, &.{})).len);
    try t.expectEqual(@as(usize, 2), (try keywords(a, back, &.{"o"}, true, &.{})).len);
}

test "listing lines" {
    const t = std.testing;
    const e = [_]Entry{.{ .name = "ls", .section = "1", .path = "p", .description = "list" }};
    const out = try listing(t.allocator, &e);
    defer t.allocator.free(out);
    try t.expectEqualStrings("ls (1) - list\n", out);
}

test "head cuts after the first section" {
    const t = std.testing;
    const src = ".TH A 1\n.SH NAME\na \\- b\n.SH SYNOPSIS\na\n";
    try t.expectEqualStrings(".TH A 1\n.SH NAME\na \\- b\n", head(src, .man));
    try t.expectEqualStrings("x\n.Sh A\n", head("x\n.Sh A\n", .mdoc));
    try t.expectEqualStrings("# A\n# B\n", head("# A\n# B\n", .markdown));
}

test "nameSection in another language and through a roff head" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("a - b", (try nameSection(a, "A(1)\n\nBEZEICHNUNG\n\n       a - b\n")).?);
    try std.testing.expectEqualStrings("a - b", (try nameSection(a, "A(1)\n\nUNBEKANNT\n\n       a - b\n")).?);
    const text = try render.render(std.testing.allocator, .man, head(".TH A 1\n.SH NAME\na \\- b\n.SH X\nz\n", .man), .{ .width = 0 });
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("a - b", (try nameSection(a, text)).?);
}

test "dedupe" {
    var e = [_]Entry{
        .{ .name = "a", .section = "1", .path = "x", .description = "d" },
        .{ .name = "a", .section = "1", .path = "y", .description = "d" },
        .{ .name = "a", .section = "1", .path = "z", .description = "other" },
    };
    try std.testing.expectEqual(@as(usize, 2), dedupe(&e).len);
}

//! dkman: find, search and show manual pages and Markdown documents.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const paths = @import("paths.zig");
const page_mod = @import("page.zig");
const tui = @import("tui.zig");
const render = @import("render.zig");
const pager = @import("pager.zig");
const search = @import("search.zig");

const usage =
    \\usage: dkman [options] [SECTION] NAME...
    \\       dkman [options] -l FILE...
    \\       dkman -k WORD
    \\       dkman -f [WORD]
    \\
    \\  -l FILE      show a file (a path, or - for standard input)
    \\  -w           print the path of the page instead of showing it
    \\  -k WORD      list pages whose name contains WORD
    \\  -f [WORD]    browse pages: search on the left, preview on the right
    \\               (WORD is the first search text)
    \\  --width N    wrap at N columns (default: $COLUMNS or 80)
    \\  --no-color   no ANSI styles (also off when not on a terminal or NO_COLOR is set)
    \\  --no-pager   write to standard output
    \\  -h, --help   this text
    \\
;

const Mode = enum { show, local, where, keyword, browse };

const Config = struct {
    mode: Mode = .show,
    width: ?usize = null,
    color: bool = true,
    pager: bool = true,
    section: ?[]const u8 = null,
    words: []const []const u8 = &.{},
};

const ParseError = error{Usage};

fn parseArgs(arena: Allocator, args: []const [:0]const u8) (ParseError || Allocator.Error)!Config {
    var cfg: Config = .{};
    var words: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a: []const u8 = args[i];
        if (std.mem.eql(u8, a, "-l")) {
            cfg.mode = .local;
        } else if (std.mem.eql(u8, a, "-w")) {
            cfg.mode = .where;
        } else if (std.mem.eql(u8, a, "-k")) {
            cfg.mode = .keyword;
        } else if (std.mem.eql(u8, a, "-f")) {
            cfg.mode = .browse;
        } else if (std.mem.eql(u8, a, "--no-color")) {
            cfg.color = false;
        } else if (std.mem.eql(u8, a, "--no-pager")) {
            cfg.pager = false;
        } else if (std.mem.eql(u8, a, "--width")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            cfg.width = std.fmt.parseInt(usize, args[i], 10) catch return error.Usage;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            return error.Usage;
        } else if (a.len > 1 and a[0] == '-') {
            return error.Usage;
        } else try words.append(arena, a);
    }
    // `dkman 3 printf`: a leading section number before the page name.
    if ((cfg.mode == .show or cfg.mode == .where) and words.items.len >= 2 and isSection(words.items[0])) {
        cfg.section = words.items[0];
        words.items = words.items[1..];
    }
    cfg.words = words.items;
    return cfg;
}

fn isSection(s: []const u8) bool {
    return s.len > 0 and s.len <= 4 and (std.ascii.isDigit(s[0]) or s[0] == 'n' or s[0] == 'l') and
        std.ascii.isAlphanumeric(s[s.len - 1]);
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    const cfg = parseArgs(arena, args) catch |err| switch (err) {
        error.Usage => {
            try Io.File.stderr().writeStreamingAll(io, usage);
            return 2;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };

    const stdout_tty = Io.File.stdout().isTty(io) catch false;
    const no_color_env = if (init.environ_map.get("NO_COLOR")) |v| v.len > 0 else false;
    const opts: render.Options = .{
        .width = cfg.width orelse widthFromEnv(init.environ_map.get("COLUMNS")),
        .color = cfg.color and stdout_tty and !no_color_env,
    };
    const use_pager = cfg.pager and stdout_tty;
    const pager_cmd = init.environ_map.get("PAGER") orelse "less -R";

    const dirs = try paths.searchDirs(arena, init.environ_map.get("MANPATH"));

    switch (cfg.mode) {
        .local => {
            if (cfg.words.len == 0) return usageError(io);
            var status: u8 = 0;
            for (cfg.words) |w| {
                if (!try showFile(gpa, arena, io, dirs, w, opts, use_pager, pager_cmd)) status = 1;
            }
            return status;
        },
        .show, .where => {
            if (cfg.words.len == 0) return usageError(io);
            var status: u8 = 0;
            for (cfg.words) |name| {
                // A name with a slash is a path, as with man(1).
                if (std.mem.indexOfScalar(u8, name, '/') != null) {
                    if (cfg.mode == .where) {
                        try printLine(io, name);
                    } else if (!try showFile(gpa, arena, io, dirs, name, opts, use_pager, pager_cmd)) status = 1;
                    continue;
                }
                const page = try paths.find(arena, io, dirs, name, cfg.section) orelse {
                    try diag(io, "dkman: no manual entry for {s}\n", .{name});
                    status = 1;
                    continue;
                };
                if (cfg.mode == .where) {
                    try printLine(io, page.path);
                } else if (!try showFile(gpa, arena, io, dirs, page.path, opts, use_pager, pager_cmd)) status = 1;
            }
            return status;
        },
        .keyword => {
            if (cfg.words.len != 1) return usageError(io);
            const pages = try paths.scan(arena, io, dirs, null, null);
            var hits: std.ArrayList(paths.Page) = .empty;
            for (pages) |p| {
                if (std.mem.find(u8, p.name, cfg.words[0]) != null) try hits.append(arena, p);
            }
            if (hits.items.len == 0) {
                try diag(io, "dkman: nothing appropriate for {s}\n", .{cfg.words[0]});
                return 1;
            }
            const menu = try search.menuText(gpa, hits.items);
            defer gpa.free(menu);
            try pager.writeStdout(io, menu);
            return 0;
        },
        .browse => {
            const pages = try paths.scan(arena, io, dirs, null, null);
            if (pages.len == 0) {
                try diag(io, "dkman: no manual pages found in the search path\n", .{});
                return 1;
            }
            search.sortByName(pages);
            var query: []const u8 = if (cfg.words.len > 0) cfg.words[0] else "";
            var select: ?[]const u8 = null;
            var status: u8 = 0;
            // Back to the browser after each page, with the same search.
            while (true) {
                const chosen = tui.run(gpa, io, dirs, pages, .{ .color = opts.color, .query = query, .select = select }) catch |err| switch (err) {
                    error.NotATerminal => {
                        try diag(io, "dkman: -f needs a terminal; use dkman -k WORD instead\n", .{});
                        return 1;
                    },
                    else => |e| return e,
                } orelse return status;
                defer gpa.free(chosen.path);
                defer gpa.free(chosen.query);
                query = try arena.dupe(u8, chosen.query);
                select = try arena.dupe(u8, chosen.path);
                status = if (try showFile(gpa, arena, io, dirs, chosen.path, opts, use_pager, pager_cmd)) 0 else 1;
                if (!use_pager) return status;
            }
        },
    }
}

fn usageError(io: Io) !u8 {
    try Io.File.stderr().writeStreamingAll(io, usage);
    return 2;
}

fn widthFromEnv(columns: ?[]const u8) usize {
    const c = columns orelse return 80;
    const n = std.fmt.parseInt(usize, c, 10) catch return 80;
    return if (n >= 20 and n <= 1000) n else 80;
}

fn printLine(io: Io, s: []const u8) !void {
    try pager.writeStdout(io, s);
    try pager.writeStdout(io, "\n");
}

fn diag(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch &buf;
    try Io.File.stderr().writeStreamingAll(io, msg);
}

/// Loads, renders and shows one file (`-` is standard input). Returns false
/// after reporting an error to stderr.
fn showFile(gpa: Allocator, arena: Allocator, io: Io, dirs: []const []const u8, path: []const u8, opts: render.Options, use_pager: bool, pager_cmd: []const u8) !bool {
    const text = page_mod.renderFile(gpa, arena, io, dirs, path, opts) catch |err| switch (err) {
        error.BrokenRedirect => {
            try diag(io, "dkman: {s} redirects to a page that was not found\n", .{path});
            return false;
        },
        else => {
            try diag(io, "dkman: cannot show {s}: {s}\n", .{ path, @errorName(err) });
            return false;
        },
    };
    defer gpa.free(text);

    if (use_pager) try pager.show(gpa, io, pager_cmd, text) else try pager.writeStdout(io, text);
    return true;
}

test {
    _ = @import("paths.zig");
    _ = @import("format.zig");
    _ = @import("source.zig");
    _ = @import("page.zig");
    _ = @import("tui.zig");
    _ = @import("render.zig");
    _ = @import("pager.zig");
    _ = @import("search.zig");
    _ = @import("theme.zig");
}

test "argument parsing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const t = std.testing;

    const c1 = try parseArgs(a, &.{ "dkman", "3", "printf" });
    try t.expectEqualStrings("3", c1.section.?);
    try t.expectEqual(@as(usize, 1), c1.words.len);

    // A single number is a page name, not a section.
    const c2 = try parseArgs(a, &.{ "dkman", "7" });
    try t.expect(c2.section == null);

    const c3 = try parseArgs(a, &.{ "dkman", "--width", "60", "--no-pager", "-l", "x.md" });
    try t.expectEqual(@as(usize, 60), c3.width.?);
    try t.expectEqual(Mode.local, c3.mode);
    try t.expect(!c3.pager);

    try t.expectError(error.Usage, parseArgs(a, &.{ "dkman", "--bogus" }));
    try t.expectError(error.Usage, parseArgs(a, &.{ "dkman", "--width" }));
    try t.expectError(error.Usage, parseArgs(a, &.{ "dkman", "--width", "x" }));
}

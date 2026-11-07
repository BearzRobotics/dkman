//! The page browser behind `dkman -f`: a search box with the matching pages
//! on the left and a preview of the selected page on the right. It needs no
//! other program; the terminal is driven with plain escape sequences.
//!
//!     Type          narrow the list (several words must all match)
//!     Up/Down       move the selection (also Ctrl-P, Ctrl-N, Ctrl-K)
//!     PgUp/PgDn     scroll the preview (also Ctrl-B, Ctrl-F)
//!     Shift-Up/Down scroll the preview by one line
//!     Home/End      preview to the top or the bottom
//!     Enter         open the page in the pager
//!     Esc, Ctrl-C   leave

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const posix = std.posix;
const paths = @import("paths.zig");
const page_mod = @import("page.zig");
const render = @import("render.zig");

pub const Options = struct {
    /// Color in the preview and the chrome. Without it only bold, dim and reverse are used.
    color: bool = true,
    /// The first search text.
    query: []const u8 = "",
    /// A page path to select first, when it matches the query.
    select: ?[]const u8 = null,
};

pub const Result = struct {
    /// The chosen page file; owned by the caller.
    path: []u8,
    /// The search text at that moment; owned by the caller.
    query: []u8,
};

pub const NotATerminal = error{NotATerminal};

// ---------------------------------------------------------------- matching

/// How well `term` (lowercase) matches `hay` (lowercase), or null for no match.
/// A whole name beats a prefix, a prefix beats a substring, a substring beats
/// letters that merely appear in order.
pub fn score(hay: []const u8, term: []const u8) ?i32 {
    if (term.len == 0) return 0;
    const name = hay[0 .. std.mem.indexOfScalar(u8, hay, '(') orelse hay.len];
    if (std.mem.eql(u8, name, term)) return 1000;
    if (std.mem.startsWith(u8, hay, term)) return 800 - @as(i32, @intCast(@min(hay.len - term.len, 100)));
    if (std.mem.find(u8, hay, term)) |at| {
        var s: i32 = 600 - @as(i32, @intCast(@min(at, 100)));
        if (at > 0 and (hay[at - 1] == '-' or hay[at - 1] == '_' or hay[at - 1] == '.')) s += 50;
        return s;
    }
    // Letters in order, anywhere.
    var first: usize = 0;
    var last: usize = 0;
    var ti: usize = 0;
    for (hay, 0..) |c, i| {
        if (c != term[ti]) continue;
        if (ti == 0) first = i;
        last = i;
        ti += 1;
        if (ti == term.len) break;
    }
    if (ti < term.len) return null;
    const gap = (last - first + 1) - term.len;
    return 300 - @as(i32, @intCast(@min(gap, 250)));
}

/// Score of the whole query: every space separated word must match.
pub fn scoreQuery(hay: []const u8, query_lower: []const u8) ?i32 {
    var total: i32 = 0;
    var it = std.mem.tokenizeScalar(u8, query_lower, ' ');
    while (it.next()) |term| total += score(hay, term) orelse return null;
    return total;
}

// ------------------------------------------------------------- text helpers

/// Number of characters (UTF-8 code points) in `s`.
fn charCount(s: []const u8) usize {
    var n: usize = 0;
    for (s) |c| {
        if (c & 0xc0 != 0x80) n += 1;
    }
    return n;
}

/// The longest prefix of `s` with at most `max` characters.
fn charPrefix(s: []const u8, max: usize) []const u8 {
    var n: usize = 0;
    for (s, 0..) |c, i| {
        if (c & 0xc0 != 0x80) {
            if (n == max) return s[0..i];
            n += 1;
        }
    }
    return s;
}

/// Appends `s` cut to `max` visible columns. Escape sequences are copied but
/// not counted, tabs become spaces and other control characters are dropped.
/// Ends with a style reset when `s` held any escape.
fn appendClipped(gpa: Allocator, out: *std.ArrayList(u8), s: []const u8, max: usize) Allocator.Error!usize {
    var col: usize = 0;
    var i: usize = 0;
    var styled = false;
    while (i < s.len) {
        const c = s[i];
        if (c == 0x1b) {
            // Copy the whole sequence.
            var j = i + 1;
            if (j < s.len and s[j] == '[') {
                j += 1;
                while (j < s.len and s[j] >= 0x20 and s[j] <= 0x3f) j += 1;
                if (j < s.len) j += 1;
            }
            try out.appendSlice(gpa, s[i..j]);
            styled = true;
            i = j;
        } else if (c == '\t') {
            const n = @min(8 - col % 8, max - col);
            try out.appendNTimes(gpa, ' ', n);
            col += n;
            i += 1;
            if (col >= max) break;
        } else if (c < 0x20 or c == 0x7f) {
            i += 1;
        } else if (c & 0xc0 == 0x80) {
            try out.append(gpa, c);
            i += 1;
        } else {
            if (col >= max) break;
            try out.append(gpa, c);
            col += 1;
            i += 1;
        }
    }
    // Finish a code point that was started.
    while (i < s.len and s[i] & 0xc0 == 0x80) : (i += 1) try out.append(gpa, s[i]);
    if (styled) try out.appendSlice(gpa, "\x1b[0m");
    return col;
}

// ----------------------------------------------------------------- terminal

const Size = struct { rows: usize, cols: usize };

fn terminalSize() Size {
    if (builtin.os.tag == .linux) {
        var ws: posix.winsize = undefined;
        const rc = std.os.linux.ioctl(1, std.os.linux.T.IOCGWINSZ, @intFromPtr(&ws));
        if (std.os.linux.errno(rc) == .SUCCESS and ws.col > 0 and ws.row > 0) {
            return .{ .rows = ws.row, .cols = ws.col };
        }
    }
    return .{ .rows = 24, .cols = 80 };
}

fn inputPending(timeout_ms: i32) bool {
    var fds = [_]posix.pollfd{.{ .fd = 0, .events = posix.POLL.IN }};
    const n = posix.poll(&fds, timeout_ms) catch return false;
    return n > 0;
}

const RawMode = struct {
    saved: posix.termios,

    fn enter() !RawMode {
        const saved = posix.tcgetattr(0) catch return error.NotATerminal;
        var raw = saved;
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;
        raw.iflag.BRKINT = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.cc[@intFromEnum(std.os.linux.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.os.linux.V.TIME)] = 0;
        try posix.tcsetattr(0, .FLUSH, raw);
        return .{ .saved = saved };
    }

    fn leave(r: RawMode) void {
        posix.tcsetattr(0, .FLUSH, r.saved) catch {};
    }
};

// -------------------------------------------------------------------- state

const Action = enum { none, accept, cancel };

const Tui = struct {
    gpa: Allocator,
    io: Io,
    dirs: []const []const u8,
    pages: []const paths.Page,
    color: bool,
    /// `name(section)` in lowercase, one per page.
    hay: [][]u8,

    query: std.ArrayList(u8) = .empty,
    /// Indices into `pages`, best match first.
    hits: std.ArrayList(u32) = .empty,
    sel: usize = 0,
    top: usize = 0,

    size: Size = .{ .rows = 24, .cols = 80 },

    preview_text: ?[]u8 = null,
    preview_lines: std.ArrayList([]const u8) = .empty,
    /// The page index the preview shows, and the width it was rendered at.
    preview_for: ?u32 = null,
    preview_width: usize = 0,
    preview_scroll: usize = 0,
    preview_stale: bool = true,

    out: std.ArrayList(u8) = .empty,

    fn deinit(t: *Tui) void {
        for (t.hay) |h| t.gpa.free(h);
        t.gpa.free(t.hay);
        t.query.deinit(t.gpa);
        t.hits.deinit(t.gpa);
        if (t.preview_text) |p| t.gpa.free(p);
        t.preview_lines.deinit(t.gpa);
        t.out.deinit(t.gpa);
    }

    // ------------------------------------------------------------ geometry

    fn showPreview(t: *const Tui) bool {
        return t.size.cols >= 70;
    }

    fn leftWidth(t: *const Tui) usize {
        if (!t.showPreview()) return t.size.cols;
        return std.math.clamp(t.size.cols / 3, 24, 44);
    }

    /// Columns of the preview text.
    fn previewWidth(t: *const Tui) usize {
        // left pane, a rule, a space, and one spare column at the right edge.
        return t.size.cols -| (t.leftWidth() + 3);
    }

    fn listRows(t: *const Tui) usize {
        return t.size.rows -| 2;
    }

    fn previewRows(t: *const Tui) usize {
        return t.size.rows -| 1;
    }

    // ----------------------------------------------------------- filtering

    const Scored = struct { score: i32, index: u32 };

    fn lessScored(_: void, a: Scored, b: Scored) bool {
        if (a.score != b.score) return a.score > b.score;
        return a.index < b.index;
    }

    fn refilter(t: *Tui) Allocator.Error!void {
        t.hits.clearRetainingCapacity();
        const q = try t.gpa.dupe(u8, t.query.items);
        defer t.gpa.free(q);
        for (q) |*c| c.* = std.ascii.toLower(c.*);

        if (std.mem.trim(u8, q, " ").len == 0) {
            try t.hits.ensureTotalCapacity(t.gpa, t.pages.len);
            for (0..t.pages.len) |i| t.hits.appendAssumeCapacity(@intCast(i));
        } else {
            var scored: std.ArrayList(Scored) = .empty;
            defer scored.deinit(t.gpa);
            for (t.hay, 0..) |h, i| {
                if (scoreQuery(h, q)) |s| try scored.append(t.gpa, .{ .score = s, .index = @intCast(i) });
            }
            std.mem.sort(Scored, scored.items, {}, lessScored);
            try t.hits.ensureTotalCapacity(t.gpa, scored.items.len);
            for (scored.items) |s| t.hits.appendAssumeCapacity(s.index);
        }
        t.sel = 0;
        t.top = 0;
    }

    fn current(t: *const Tui) ?u32 {
        if (t.hits.items.len == 0) return null;
        return t.hits.items[t.sel];
    }

    fn select(t: *Tui, path: []const u8) void {
        for (t.hits.items, 0..) |pi, i| {
            if (std.mem.eql(u8, t.pages[pi].path, path)) {
                t.sel = i;
                return;
            }
        }
    }

    fn moveSelection(t: *Tui, delta: isize) void {
        const n = t.hits.items.len;
        if (n == 0) return;
        const next = @as(isize, @intCast(t.sel)) + delta;
        t.sel = @intCast(std.math.clamp(next, 0, @as(isize, @intCast(n - 1))));
    }

    fn keepSelectionVisible(t: *Tui) void {
        const rows = @max(t.listRows(), 1);
        if (t.sel < t.top) t.top = t.sel;
        if (t.sel >= t.top + rows) t.top = t.sel + 1 - rows;
    }

    // -------------------------------------------------------------- preview

    fn maxScroll(t: *const Tui) usize {
        return t.preview_lines.items.len -| t.previewRows();
    }

    fn scrollPreview(t: *Tui, delta: isize) void {
        const next = @as(isize, @intCast(t.preview_scroll)) + delta;
        t.preview_scroll = @intCast(std.math.clamp(next, 0, @as(isize, @intCast(t.maxScroll()))));
    }

    fn refreshPreview(t: *Tui) Allocator.Error!void {
        t.preview_stale = false;
        t.preview_lines.clearRetainingCapacity();
        if (t.preview_text) |p| t.gpa.free(p);
        t.preview_text = null;
        t.preview_for = t.current();
        t.preview_width = t.previewWidth();
        t.preview_scroll = 0;
        if (!t.showPreview()) return;
        const idx = t.preview_for orelse return;

        var arena_state = std.heap.ArenaAllocator.init(t.gpa);
        defer arena_state.deinit();
        const opts: render.Options = .{ .width = @max(t.preview_width, 20), .color = t.color };
        const text = page_mod.renderFile(t.gpa, arena_state.allocator(), t.io, t.dirs, t.pages[idx].path, opts) catch |err| blk: {
            break :blk try std.fmt.allocPrint(t.gpa, "cannot show this page: {s}\n", .{@errorName(err)});
        };
        t.preview_text = text;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |l| try t.preview_lines.append(t.gpa, std.mem.trimEnd(u8, l, "\r"));
        // The text ends with a newline: do not show an empty last line.
        if (t.preview_lines.items.len > 0 and t.preview_lines.items[t.preview_lines.items.len - 1].len == 0) {
            _ = t.preview_lines.pop();
        }
    }

    // ----------------------------------------------------------------- keys

    fn queryChanged(t: *Tui) !void {
        try t.refilter();
    }

    fn deleteBack(t: *Tui) void {
        if (t.query.items.len == 0) return;
        var n = t.query.items.len - 1;
        while (n > 0 and t.query.items[n] & 0xc0 == 0x80) n -= 1;
        t.query.shrinkRetainingCapacity(n);
    }

    fn deleteWord(t: *Tui) void {
        var n = t.query.items.len;
        while (n > 0 and t.query.items[n - 1] == ' ') n -= 1;
        while (n > 0 and t.query.items[n - 1] != ' ') n -= 1;
        t.query.shrinkRetainingCapacity(n);
    }

    /// Handles one read from the keyboard.
    fn handle(t: *Tui, keys: []const u8) !Action {
        var changed = false;
        var i: usize = 0;
        while (i < keys.len) {
            const c = keys[i];
            switch (c) {
                0x1b => {
                    if (i + 1 >= keys.len) return .cancel;
                    if (keys[i + 1] != '[' and keys[i + 1] != 'O') {
                        i += 2; // Alt + key: not used
                        continue;
                    }
                    var j = i + 2;
                    while (j < keys.len and keys[j] >= 0x30 and keys[j] <= 0x3f) j += 1;
                    if (j >= keys.len) break;
                    const params = keys[i + 2 .. j];
                    const shift = std.mem.eql(u8, params, "1;2");
                    switch (keys[j]) {
                        'A' => if (shift) t.scrollPreview(-1) else t.moveSelection(-1),
                        'B' => if (shift) t.scrollPreview(1) else t.moveSelection(1),
                        'H' => t.preview_scroll = 0,
                        'F' => t.preview_scroll = t.maxScroll(),
                        '~' => {
                            if (std.mem.eql(u8, params, "5")) t.scrollPreview(-@as(isize, @intCast(@max(t.previewRows() -| 1, 1))));
                            if (std.mem.eql(u8, params, "6")) t.scrollPreview(@intCast(@max(t.previewRows() -| 1, 1)));
                            if (std.mem.eql(u8, params, "1") or std.mem.eql(u8, params, "7")) t.preview_scroll = 0;
                            if (std.mem.eql(u8, params, "4") or std.mem.eql(u8, params, "8")) t.preview_scroll = t.maxScroll();
                        },
                        else => {},
                    }
                    i = j + 1;
                    continue;
                },
                '\r', '\n' => if (t.current() != null) return .accept,
                3, 7 => return .cancel,
                14 => t.moveSelection(1),
                16, 11 => t.moveSelection(-1),
                6 => t.scrollPreview(@intCast(@max(t.previewRows() -| 1, 1))),
                2 => t.scrollPreview(-@as(isize, @intCast(@max(t.previewRows() -| 1, 1)))),
                21 => {
                    t.query.clearRetainingCapacity();
                    changed = true;
                },
                23 => {
                    t.deleteWord();
                    changed = true;
                },
                8, 127 => {
                    t.deleteBack();
                    changed = true;
                },
                0x20...0x7e, 0x80...0xff => {
                    try t.query.append(t.gpa, c);
                    changed = true;
                },
                else => {},
            }
            i += 1;
        }
        if (changed) try t.queryChanged();
        return .none;
    }

    // -------------------------------------------------------------- drawing

    fn goto(t: *Tui, row: usize, col: usize) !void {
        try t.out.print(t.gpa, "\x1b[{d};{d}H", .{ row + 1, col + 1 });
    }

    fn pad(t: *Tui, n: usize) !void {
        try t.out.appendNTimes(t.gpa, ' ', n);
    }

    fn draw(t: *Tui) !void {
        t.keepSelectionVisible();
        t.out.clearRetainingCapacity();
        const gpa = t.gpa;
        try t.out.appendSlice(gpa, "\x1b[?25l");
        const lw = t.leftWidth();
        const rows = t.size.rows;
        const show_preview = t.showPreview();
        const pw = t.previewWidth();

        for (0..rows) |row| {
            try t.goto(row, 0);
            var used: usize = 0;

            // ---- left pane
            if (row == 0) {
                if (t.color) try t.out.appendSlice(gpa, "\x1b[1;36m> \x1b[0m") else try t.out.appendSlice(gpa, "> ");
                const shown = charPrefix(t.query.items, lw -| 3);
                try t.out.appendSlice(gpa, shown);
                used = 2 + charCount(shown);
            } else if (row == 1) {
                var buf: [48]u8 = undefined;
                const info = std.fmt.bufPrint(&buf, "  {d}/{d}", .{ t.hits.items.len, t.pages.len }) catch "";
                try t.out.appendSlice(gpa, "\x1b[2m");
                try t.out.appendSlice(gpa, info);
                try t.out.appendSlice(gpa, "\x1b[0m");
                used = info.len;
            } else {
                const at = t.top + (row - 2);
                if (at < t.hits.items.len) {
                    const p = t.pages[t.hits.items[at]];
                    const selected = at == t.sel;
                    if (selected) try t.out.appendSlice(gpa, "\x1b[7m");
                    try t.out.appendSlice(gpa, if (selected) "> " else "  ");
                    const room = lw -| 2;
                    const name = charPrefix(p.name, room);
                    try t.out.appendSlice(gpa, name);
                    used = 2 + charCount(name);
                    const sec_room = room -| charCount(name);
                    if (sec_room >= p.section.len + 2) {
                        if (!selected) try t.out.appendSlice(gpa, "\x1b[2m");
                        try t.out.print(gpa, "({s})", .{p.section});
                        if (!selected) try t.out.appendSlice(gpa, "\x1b[0m");
                        used += p.section.len + 2;
                    }
                    if (selected) {
                        try t.pad(lw - used);
                        used = lw;
                        try t.out.appendSlice(gpa, "\x1b[0m");
                    }
                } else if (at == 0 and t.hits.items.len == 0) {
                    try t.out.appendSlice(gpa, "\x1b[2m  no matches\x1b[0m");
                    used = 13;
                }
            }
            if (show_preview) {
                try t.pad(lw -| used);
                try t.out.appendSlice(gpa, "\x1b[2m\xe2\x94\x82\x1b[0m ");
            } else {
                try t.out.appendSlice(gpa, "\x1b[K");
                continue;
            }

            // ---- preview pane
            if (row == 0) {
                if (t.preview_for) |pi| {
                    const p = t.pages[pi];
                    var head: std.ArrayList(u8) = .empty;
                    defer head.deinit(gpa);
                    try head.print(gpa, "{s}({s})  {s}", .{ p.name, p.section, p.path });
                    var tail: [16]u8 = undefined;
                    const pct: usize = if (t.maxScroll() == 0) 100 else t.preview_scroll * 100 / t.maxScroll();
                    const pct_text = std.fmt.bufPrint(&tail, "  {d}%", .{pct}) catch "";
                    const room = pw -| pct_text.len;
                    try t.out.appendSlice(gpa, "\x1b[1m");
                    _ = try appendClipped(gpa, &t.out, head.items, room);
                    try t.out.appendSlice(gpa, "\x1b[0m\x1b[2m");
                    try t.out.appendSlice(gpa, pct_text);
                    try t.out.appendSlice(gpa, "\x1b[0m");
                }
            } else {
                const at = t.preview_scroll + (row - 1);
                if (at < t.preview_lines.items.len) {
                    _ = try appendClipped(gpa, &t.out, t.preview_lines.items[at], pw);
                }
            }
            try t.out.appendSlice(gpa, "\x1b[0m\x1b[K");
        }
        // The cursor sits at the end of the search text.
        const q_cols = charCount(charPrefix(t.query.items, lw -| 3));
        try t.goto(0, 2 + q_cols);
        try t.out.appendSlice(gpa, "\x1b[?25h");
        try Io.File.stdout().writeStreamingAll(t.io, t.out.items);
    }

    fn updateSize(t: *Tui) bool {
        const s = terminalSize();
        if (s.rows == t.size.rows and s.cols == t.size.cols) return false;
        t.size = s;
        return true;
    }
};

/// Runs the browser over `pages` (sorted as they should be listed). Returns
/// the chosen page, or null when the user leaves without choosing.
pub fn run(gpa: Allocator, io: Io, dirs: []const []const u8, pages: []const paths.Page, opts: Options) !?Result {
    const stdin_tty = Io.File.stdin().isTty(io) catch false;
    const stdout_tty = Io.File.stdout().isTty(io) catch false;
    if (!stdin_tty or !stdout_tty or builtin.os.tag == .windows) return error.NotATerminal;

    var hay = try gpa.alloc([]u8, pages.len);
    var made: usize = 0;
    errdefer {
        for (hay[0..made]) |h| gpa.free(h);
        gpa.free(hay);
    }
    for (pages, 0..) |p, i| {
        const h = try std.fmt.allocPrint(gpa, "{s}({s})", .{ p.name, p.section });
        for (h) |*c| c.* = std.ascii.toLower(c.*);
        hay[i] = h;
        made = i + 1;
    }

    var t: Tui = .{ .gpa = gpa, .io = io, .dirs = dirs, .pages = pages, .color = opts.color, .hay = hay };
    defer t.deinit();
    try t.query.appendSlice(gpa, opts.query);
    try t.refilter();
    if (opts.select) |s| t.select(s);
    t.size = terminalSize();

    const raw = try RawMode.enter();
    defer raw.leave();
    try Io.File.stdout().writeStreamingAll(io, "\x1b[?1049h");
    defer Io.File.stdout().writeStreamingAll(io, "\x1b[0m\x1b[?25h\x1b[?1049l") catch {};

    var dirty = true;
    var shown_for: ?u32 = null;
    var action: Action = .none;
    while (action == .none) {
        const pending = inputPending(0);
        if (!pending) {
            const cur = t.current();
            if (t.preview_stale or cur != shown_for) {
                try t.refreshPreview();
                shown_for = cur;
                dirty = true;
            }
            if (dirty) {
                try t.draw();
                dirty = false;
            }
        }
        if (!pending and !inputPending(300)) {
            if (t.updateSize()) {
                t.preview_stale = true;
                dirty = true;
            }
            continue;
        }
        var buf: [256]u8 = undefined;
        const n = posix.read(0, &buf) catch return null;
        if (n == 0) return null;
        action = try t.handle(buf[0..n]);
        dirty = true;
    }

    if (action == .cancel) return null;
    const idx = t.current() orelse return null;
    const path = try gpa.dupe(u8, pages[idx].path);
    errdefer gpa.free(path);
    const query = try gpa.dupe(u8, t.query.items);
    return .{ .path = path, .query = query };
}

// -------------------------------------------------------------------- tests

test "ranking: name, prefix, substring, letters in order" {
    const t = std.testing;
    const exact = score("ls(1)", "ls").?;
    const prefix = score("lsblk(8)", "ls").?;
    const sub = score("pls(1)", "ls").?;
    const seq = score("l_x_s(1)", "ls").?;
    try t.expect(exact > prefix and prefix > sub and sub > seq);
    try t.expect(score("cat(1)", "z") == null);
    try t.expect(score("cat(1)", "") == 0);
}

test "every word of the query must match" {
    const t = std.testing;
    try t.expect(scoreQuery("printf(3)", "pri 3") != null);
    try t.expect(scoreQuery("printf(3)", "pri 1") == null);
    try t.expect(scoreQuery("printf(3)", "") != null);
}

test "clipping counts columns, not escapes" {
    const t = std.testing;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.allocator);
    const cols = try appendClipped(t.allocator, &out, "\x1b[1mabcdef\x1b[0m", 3);
    try t.expectEqual(@as(usize, 3), cols);
    try t.expectEqualStrings("\x1b[1mabc\x1b[0m", out.items);

    out.clearRetainingCapacity();
    _ = try appendClipped(t.allocator, &out, "a\tb", 80);
    try t.expectEqualStrings("a       b", out.items);

    out.clearRetainingCapacity();
    _ = try appendClipped(t.allocator, &out, "h\xc3\xa9llo", 2);
    try t.expectEqualStrings("h\xc3\xa9", out.items);
}

test "character helpers" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 2), charCount("h\xc3\xa9"));
    try t.expectEqualStrings("h\xc3\xa9", charPrefix("h\xc3\xa9llo", 2));
    try t.expectEqualStrings("abc", charPrefix("abc", 10));
}

fn testTui(pages: []const paths.Page) !Tui {
    const hay = try std.testing.allocator.alloc([]u8, pages.len);
    for (pages, 0..) |p, i| {
        hay[i] = try std.fmt.allocPrint(std.testing.allocator, "{s}({s})", .{ p.name, p.section });
    }
    var t: Tui = .{ .gpa = std.testing.allocator, .io = undefined, .dirs = &.{}, .pages = pages, .color = false, .hay = hay };
    try t.refilter();
    return t;
}

const test_pages = [_]paths.Page{
    .{ .name = "cat", .section = "1", .path = "/m/man1/cat.1", .dir_index = 0 },
    .{ .name = "printf", .section = "1", .path = "/m/man1/printf.1", .dir_index = 0 },
    .{ .name = "printf", .section = "3", .path = "/m/man3/printf.3", .dir_index = 0 },
};

test "typing filters, backspace and Ctrl-U widen again" {
    const t = std.testing;
    var tui = try testTui(&test_pages);
    defer tui.deinit();
    try t.expectEqual(@as(usize, 3), tui.hits.items.len);

    try t.expectEqual(Action.none, try tui.handle("prin"));
    try t.expectEqual(@as(usize, 2), tui.hits.items.len);
    try t.expectEqual(Action.none, try tui.handle("tf 3"));
    try t.expectEqual(@as(usize, 1), tui.hits.items.len);
    try t.expectEqual(@as(u32, 2), tui.current().?);

    _ = try tui.handle("\x7f\x7f");
    try t.expectEqualStrings("printf", tui.query.items);
    try t.expectEqual(@as(usize, 2), tui.hits.items.len);
    _ = try tui.handle("\x15");
    try t.expectEqual(@as(usize, 3), tui.hits.items.len);
}

test "arrows move the selection and stay in range" {
    const t = std.testing;
    var tui = try testTui(&test_pages);
    defer tui.deinit();
    _ = try tui.handle("\x1b[A");
    try t.expectEqual(@as(usize, 0), tui.sel);
    _ = try tui.handle("\x1b[B\x1b[B\x1b[B\x1b[B");
    try t.expectEqual(@as(usize, 2), tui.sel);
    _ = try tui.handle("\x10"); // Ctrl-P
    try t.expectEqual(@as(usize, 1), tui.sel);
    _ = try tui.handle("\x0e"); // Ctrl-N
    try t.expectEqual(@as(usize, 2), tui.sel);
}

test "Enter accepts, Esc and Ctrl-C cancel, Enter with no match does nothing" {
    const t = std.testing;
    var tui = try testTui(&test_pages);
    defer tui.deinit();
    try t.expectEqual(Action.accept, try tui.handle("\r"));
    try t.expectEqual(Action.cancel, try tui.handle("\x1b"));
    try t.expectEqual(Action.cancel, try tui.handle("\x03"));
    _ = try tui.handle("zzz");
    try t.expectEqual(@as(usize, 0), tui.hits.items.len);
    try t.expectEqual(Action.none, try tui.handle("\r"));
}

test "preview scrolling is clamped" {
    const t = std.testing;
    var tui = try testTui(&test_pages);
    defer tui.deinit();
    tui.size = .{ .rows = 10, .cols = 100 };
    for (0..30) |_| try tui.preview_lines.append(t.allocator, "line");
    _ = try tui.handle("\x1b[6~"); // PgDn: rows-2 lines
    try t.expectEqual(@as(usize, 8), tui.preview_scroll);
    _ = try tui.handle("\x1b[F");
    try t.expectEqual(@as(usize, 21), tui.preview_scroll);
    _ = try tui.handle("\x1b[6~");
    try t.expectEqual(@as(usize, 21), tui.preview_scroll);
    _ = try tui.handle("\x1b[1;2A"); // Shift-Up: one line
    try t.expectEqual(@as(usize, 20), tui.preview_scroll);
    _ = try tui.handle("\x1b[H");
    try t.expectEqual(@as(usize, 0), tui.preview_scroll);
    _ = try tui.handle("\x1b[5~");
    try t.expectEqual(@as(usize, 0), tui.preview_scroll);
}

test "a multi-byte character is deleted whole" {
    const t = std.testing;
    var tui = try testTui(&test_pages);
    defer tui.deinit();
    _ = try tui.handle("a\xc3\xa9");
    _ = try tui.handle("\x7f");
    try t.expectEqualStrings("a", tui.query.items);
}

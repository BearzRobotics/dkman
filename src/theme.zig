//! A color theme for rendered pages.
//!
//! md-zig writes terminal text with only bold, italic, underline and two
//! foreground colors. This pass reads that stream again and restyles it the
//! way a manual page reads best:
//!
//!   - a line that is bold from end to end, starting in column 0, is a heading
//!   - bold text (commands, options) is green, italic text (arguments) cyan
//!   - inline code is magenta, links are underlined blue
//!   - page references such as `printf(3)` are bold magenta
//!
//! The input is whatever `toTextAlloc` wrote with `.color = true`; escape
//! sequences other than SGR pass through untouched.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Attr = struct {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    strike: bool = false,
    code: bool = false,
    link: bool = false,

    fn plain(a: Attr) bool {
        return !(a.bold or a.dim or a.italic or a.underline or a.strike or a.code or a.link);
    }

    /// Applies the parameters of one SGR sequence (`1;3`, empty means reset).
    fn apply(a: *Attr, params: []const u8) void {
        if (params.len == 0) {
            a.* = .{};
            return;
        }
        var it = std.mem.splitScalar(u8, params, ';');
        while (it.next()) |p| {
            const n = std.fmt.parseInt(u8, if (p.len == 0) "0" else p, 10) catch continue;
            switch (n) {
                0 => a.* = .{},
                1 => a.bold = true,
                2 => a.dim = true,
                3 => a.italic = true,
                4 => a.underline = true,
                9 => a.strike = true,
                22 => {
                    a.bold = false;
                    a.dim = false;
                },
                23 => a.italic = false,
                24 => a.underline = false,
                29 => a.strike = false,
                34 => a.link = true,
                36 => a.code = true,
                39 => {
                    a.link = false;
                    a.code = false;
                },
                else => {},
            }
        }
    }
};

/// Which role a stretch of text plays; decides its colors.
const Role = enum { normal, heading, ref };

const Style = struct {
    buf: [48]u8 = undefined,
    len: usize = 0,

    fn text(s: *const Style) []const u8 {
        return s.buf[0..s.len];
    }

    fn add(s: *Style, code: []const u8) void {
        if (s.len > 0) {
            s.buf[s.len] = ';';
            s.len += 1;
        }
        @memcpy(s.buf[s.len..][0..code.len], code);
        s.len += code.len;
    }
};

/// The SGR parameters (without `ESC[` and `m`) for text with `a` in `role`;
/// empty means the terminal default.
fn styleFor(a: Attr, role: Role) Style {
    var s: Style = .{};
    switch (role) {
        .heading => {
            s.add("1");
            s.add("33");
            return s;
        },
        .ref => {
            s.add("1");
            s.add("35");
            return s;
        },
        .normal => {},
    }
    if (a.bold) s.add("1");
    if (a.dim) s.add("2");
    if (a.italic) s.add("3");
    if (a.underline or a.link) s.add("4");
    if (a.strike) s.add("9");
    // One foreground color, strongest meaning first.
    if (a.link) {
        s.add("34");
    } else if (a.code) {
        s.add("35");
    } else if (a.bold) {
        s.add("32");
    } else if (a.italic) {
        s.add("36");
    }
    return s;
}

const Token = union(enum) {
    /// An SGR sequence; the slice holds its parameters.
    sgr: []const u8,
    /// Any other escape sequence, to copy as it is.
    other: []const u8,
    text: []const u8,
};

/// Splits one line into escape sequences and text.
const Lexer = struct {
    line: []const u8,
    pos: usize = 0,

    fn next(l: *Lexer) ?Token {
        if (l.pos >= l.line.len) return null;
        const rest = l.line[l.pos..];
        if (rest[0] == 0x1b) {
            if (rest.len >= 2 and rest[1] == '[') {
                var i: usize = 2;
                while (i < rest.len and rest[i] >= 0x30 and rest[i] <= 0x3f) i += 1;
                while (i < rest.len and rest[i] >= 0x20 and rest[i] <= 0x2f) i += 1;
                if (i < rest.len) {
                    const final = rest[i];
                    const whole = rest[0 .. i + 1];
                    l.pos += i + 1;
                    if (final == 'm') {
                        const params = rest[2..i];
                        for (params) |c| if (!(std.ascii.isDigit(c) or c == ';')) return .{ .other = whole };
                        return .{ .sgr = params };
                    }
                    return .{ .other = whole };
                }
            }
            // A lone or unterminated escape: pass it on.
            l.pos += 1;
            return .{ .other = rest[0..1] };
        }
        var i: usize = 1;
        while (i < rest.len and rest[i] != 0x1b) i += 1;
        l.pos += i;
        return .{ .text = rest[0..i] };
    }
};

/// True when the line has visible text, the first of it in column 0, and all
/// of it bold.
fn isHeading(line: []const u8, start: Attr) bool {
    var attr = start;
    var lx: Lexer = .{ .line = line };
    var seen = false;
    while (lx.next()) |tok| switch (tok) {
        .sgr => |p| attr.apply(p),
        .other => {},
        .text => |t| {
            for (t) |c| {
                if (c == ' ' or c == '\t') {
                    if (!seen) return false;
                    continue;
                }
                if (!attr.bold) return false;
                seen = true;
            }
        },
    };
    return seen;
}

/// Length of a page reference `name(1)` that ends the slice, or 0.
fn refStart(t: []const u8, from: usize) ?struct { start: usize, end: usize } {
    var i = from;
    while (i < t.len) : (i += 1) {
        if (t[i] != '(') continue;
        // The section: digits and letters, then `)`.
        var j = i + 1;
        if (j >= t.len or !std.ascii.isDigit(t[j])) continue;
        while (j < t.len and std.ascii.isAlphanumeric(t[j])) j += 1;
        if (j >= t.len or t[j] != ')') continue;
        // The name before it.
        var s = i;
        while (s > 0 and isNameChar(t[s - 1])) s -= 1;
        if (s == i) continue;
        return .{ .start = s, .end = j + 1 };
    }
    return null;
}

fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.' or c == '+' or c == ':';
}

/// `(1)` at the very start of `t`: the tail of a reference whose name was bold.
fn leadingSection(t: []const u8) usize {
    if (t.len < 3 or t[0] != '(' or !std.ascii.isDigit(t[1])) return 0;
    var j: usize = 2;
    while (j < t.len and std.ascii.isAlphanumeric(t[j])) j += 1;
    return if (j < t.len and t[j] == ')') j + 1 else 0;
}

const Writer = struct {
    gpa: Allocator,
    out: std.ArrayList(u8) = .empty,
    /// The style currently active on the terminal (SGR parameters).
    current: Style = .{},

    fn setStyle(w: *Writer, want: Style) Allocator.Error!void {
        if (std.mem.eql(u8, w.current.text(), want.text())) return;
        if (w.current.len > 0) try w.out.appendSlice(w.gpa, "\x1b[0m");
        if (want.len > 0) {
            try w.out.appendSlice(w.gpa, "\x1b[");
            try w.out.appendSlice(w.gpa, want.text());
            try w.out.append(w.gpa, 'm');
        }
        w.current = want;
    }

    fn put(w: *Writer, attr: Attr, role: Role, t: []const u8) Allocator.Error!void {
        if (t.len == 0) return;
        try w.setStyle(styleFor(attr, role));
        try w.out.appendSlice(w.gpa, t);
    }
};

/// Restyles `text`, which holds md-zig's colored output. The caller owns the
/// result.
pub fn apply(gpa: Allocator, text: []const u8) Allocator.Error![]u8 {
    var w: Writer = .{ .gpa = gpa };
    errdefer w.out.deinit(gpa);
    try w.out.ensureTotalCapacity(gpa, text.len + text.len / 4);

    var attr: Attr = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) {
            try w.setStyle(.{});
            try w.out.append(gpa, '\n');
        }
        first = false;

        const heading = isHeading(line, attr);
        var lx: Lexer = .{ .line = line };
        // True while the text just written was bold, for `name(1)` tails.
        var after_bold = false;
        while (lx.next()) |tok| switch (tok) {
            .sgr => |p| attr.apply(p),
            .other => |o| try w.out.appendSlice(gpa, o),
            .text => |t| {
                if (heading) {
                    try w.put(attr, .heading, t);
                    continue;
                }
                var rest = t;
                if (after_bold and attr.plain()) {
                    const n = leadingSection(rest);
                    if (n > 0) {
                        try w.put(.{ .bold = true }, .normal, rest[0..n]);
                        rest = rest[n..];
                    }
                }
                if (attr.plain()) {
                    while (refStart(rest, 0)) |r| {
                        try w.put(attr, .normal, rest[0..r.start]);
                        try w.put(attr, .ref, rest[r.start..r.end]);
                        rest = rest[r.end..];
                    }
                }
                try w.put(attr, .normal, rest);
                after_bold = attr.bold and !attr.code and !attr.link;
            },
        };
    }
    try w.setStyle(.{});
    return w.out.toOwnedSlice(gpa);
}

test "headings, options and arguments get their colors" {
    const t = std.testing;
    const out = try apply(t.allocator, "\x1b[0m\x1b[1mNAME\x1b[0m\x1b[0m\n  \x1b[0m\x1b[1m-a\x1b[0m \x1b[3mFILE\x1b[0m\n");
    defer t.allocator.free(out);
    try t.expectEqualStrings("\x1b[1;33mNAME\x1b[0m\n  \x1b[1;32m-a\x1b[0m \x1b[3;36mFILE\x1b[0m\n", out);
}

test "page references are recognised, also after a bold name" {
    const t = std.testing;
    const out = try apply(t.allocator, "see printf(3) and \x1b[1mls\x1b[0m(1).\n");
    defer t.allocator.free(out);
    try t.expectEqualStrings("see \x1b[1;35mprintf(3)\x1b[0m and \x1b[1;32mls(1)\x1b[0m.\n", out);
}

test "a paragraph that starts in bold is not a heading" {
    const t = std.testing;
    const out = try apply(t.allocator, "\x1b[1mNote\x1b[0m: more text\n");
    defer t.allocator.free(out);
    try t.expectEqualStrings("\x1b[1;32mNote\x1b[0m: more text\n", out);
}

test "plain text and other escapes pass through" {
    const t = std.testing;
    const out = try apply(t.allocator, "just text\n\x1b[2Kx\n");
    defer t.allocator.free(out);
    try t.expectEqualStrings("just text\n\x1b[2Kx\n", out);
}

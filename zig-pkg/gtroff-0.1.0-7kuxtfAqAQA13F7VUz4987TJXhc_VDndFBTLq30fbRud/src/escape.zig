//! roff escape sequences: fonts, special characters, strings, size changes.
//!
//! `segments` turns one line of roff text into runs of plain UTF-8 text, each
//! with the font that was in effect. Escapes that only affect typesetting
//! (sizes, zero-width marks, number registers) are dropped.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Font = struct {
    bold: bool = false,
    italic: bool = false,
    mono: bool = false,

    pub const roman: Font = .{};
    pub const b: Font = .{ .bold = true };
    pub const i: Font = .{ .italic = true };
    pub const bi: Font = .{ .bold = true, .italic = true };
    pub const cw: Font = .{ .mono = true };

    pub fn eql(a: Font, other: Font) bool {
        return a.bold == other.bold and a.italic == other.italic and a.mono == other.mono;
    }

    /// Font from a roff font name: R, B, I, BI, CW, CR, CB, CI ...
    pub fn fromName(name: []const u8) ?Font {
        if (name.len == 0) return null;
        if (std.mem.eql(u8, name, "R") or std.mem.eql(u8, name, "1")) return roman;
        if (std.mem.eql(u8, name, "B") or std.mem.eql(u8, name, "2")) return b;
        if (std.mem.eql(u8, name, "I") or std.mem.eql(u8, name, "3")) return i;
        if (std.mem.eql(u8, name, "BI") or std.mem.eql(u8, name, "4")) return bi;
        if (std.mem.eql(u8, name, "CW") or std.mem.eql(u8, name, "CR") or std.mem.eql(u8, name, "C")) return cw;
        if (std.mem.eql(u8, name, "CB")) return .{ .mono = true, .bold = true };
        if (std.mem.eql(u8, name, "CI")) return .{ .mono = true, .italic = true };
        return null;
    }
};

pub const Segment = struct {
    text: []const u8,
    font: Font,
};

/// State that outlives one line: the current and previous font, and the
/// string registers defined with `.ds`.
pub const State = struct {
    font: Font = .roman,
    prev: Font = .roman,
    strings: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn setFont(self: *State, f: Font) void {
        self.prev = self.font;
        self.font = f;
    }
};

/// Result of `segments`.
pub const Result = struct {
    segments: []const Segment,
    /// The line ended with `\c`: the next line continues without a space.
    continued: bool,
};

/// Named special characters (`\(xx` and `\[xxxx]`).
const specials = [_]struct { []const u8, []const u8 }{
    .{ "em", "\u{2014}" },  .{ "en", "\u{2013}" }, .{ "hy", "-" },        .{ "bu", "\u{2022}" },
    .{ "aq", "'" },         .{ "dq", "\"" },       .{ "lq", "\u{201c}" }, .{ "rq", "\u{201d}" },
    .{ "oq", "\u{2018}" },  .{ "cq", "\u{2019}" }, .{ "co", "\u{00a9}" }, .{ "rg", "\u{00ae}" },
    .{ "tm", "\u{2122}" },  .{ "ga", "`" },        .{ "ha", "^" },        .{ "ti", "~" },
    .{ "->", "\u{2192}" },  .{ "<-", "\u{2190}" }, .{ "**", "*" },        .{ "+-", "\u{00b1}" },
    .{ "mu", "\u{00d7}" },  .{ "di", "\u{00f7}" }, .{ "de", "\u{00b0}" }, .{ "fm", "\u{2032}" },
    .{ "sl", "/" },         .{ "rs", "\\" },       .{ "ba", "|" },        .{ "or", "|" },
    .{ "ru", "_" },         .{ "ul", "_" },        .{ "mi", "\u{2212}" }, .{ "pl", "+" },
    .{ "eq", "=" },         .{ "!=", "\u{2260}" }, .{ "<=", "\u{2264}" }, .{ ">=", "\u{2265}" },
    .{ "ap", "~" },         .{ "*a", "\u{03b1}" }, .{ "*b", "\u{03b2}" }, .{ "*l", "\u{03bb}" },
    .{ "*m", "\u{03bc}" },  .{ "*p", "\u{03c0}" }, .{ "ff", "ff" },       .{ "fi", "fi" },
    .{ "fl", "fl" },        .{ "Fi", "ffi" },      .{ "Fl", "ffl" },      .{ "lh", "\u{261c}" },
    .{ "rh", "\u{261e}" },  .{ "sc", "\u{00a7}" }, .{ "dg", "\u{2020}" }, .{ "dd", "\u{2021}" },
    .{ "ct", "\u{00a2}" },  .{ "Po", "\u{00a3}" }, .{ "Ye", "\u{00a5}" }, .{ "Eu", "\u{20ac}" },
    .{ "12", "\u{00bd}" },  .{ "14", "\u{00bc}" }, .{ "34", "\u{00be}" }, .{ "ff", "ff" },
    .{ "lB", "[" },         .{ "rB", "]" },        .{ "lC", "{" },        .{ "rC", "}" },
    .{ "la", "\u{27e8}" },  .{ "ra", "\u{27e9}" }, .{ "Bq", "\u{201e}" }, .{ "bq", "\u{201a}" },
    .{ "Fo", "\u{00ab}" },  .{ "Fc", "\u{00bb}" }, .{ "r!", "\u{00a1}" }, .{ "r?", "\u{00bf}" },
    .{ "a\"", "\u{02dd}" }, .{ "a-", "\u{00af}" }, .{ "a.", "\u{02d9}" }, .{ "ah", "\u{02c7}" },
    .{ "ac", "\u{00b8}" },  .{ "ad", "\u{00a8}" }, .{ "ao", "\u{00b0}" }, .{ "ho", "\u{02db}" },
    .{ "rn", "\u{203e}" },  .{ "ci", "\u{25cb}" }, .{ "sq", "\u{25a1}" }, .{ "lz", "\u{25ca}" },
    .{ "ts", "\u{03c2}" },  .{ "Of", "\u{00aa}" }, .{ "Om", "\u{00ba}" }, .{ "S1", "\u{00b9}" },
    .{ "S2", "\u{00b2}" },  .{ "S3", "\u{00b3}" }, .{ "pc", "\u{00b7}" }, .{ "no", "\u{00ac}" },
    .{ "br", "|" },         .{ "bv", "|" },        .{ "lq", "\u{201c}" }, .{ "Tm", "\u{2122}" },
};

fn special(name: []const u8) ?[]const u8 {
    for (specials) |s| if (std.mem.eql(u8, s[0], name)) return s[1];
    return null;
}

/// Predefined strings (`\*(R`, `\*(lq`, ...), used when a page has not defined its own.
fn builtinString(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "R")) return "\u{00ae}";
    if (std.mem.eql(u8, name, "lq")) return "\u{201c}";
    if (std.mem.eql(u8, name, "rq")) return "\u{201d}";
    if (std.mem.eql(u8, name, "Tm")) return "\u{2122}";
    if (std.mem.eql(u8, name, "S")) return "";
    if (std.mem.eql(u8, name, "-")) return "-";
    return null;
}

/// Reads a roff name after an escape letter: one character, `(xx` or `[name]`.
/// Returns the name and the number of bytes used after the escape letter.
fn readName(s: []const u8) ?struct { name: []const u8, used: usize } {
    if (s.len == 0) return null;
    if (s[0] == '(') {
        if (s.len < 3) return .{ .name = s[1..], .used = s.len };
        return .{ .name = s[1..3], .used = 3 };
    }
    if (s[0] == '[') {
        const end = std.mem.indexOfScalar(u8, s, ']') orelse return .{ .name = s[1..], .used = s.len };
        return .{ .name = s[1..end], .used = end + 1 };
    }
    return .{ .name = s[0..1], .used = 1 };
}

/// Encodes `\[uXXXX]` style names; returns null if `name` is not one.
fn unicodeName(name: []const u8, buf: *[4]u8) ?[]const u8 {
    if (name.len < 5 or name[0] != 'u') return null;
    const cp = std.fmt.parseInt(u21, name[1..], 16) catch return null;
    const n = std.unicode.utf8Encode(cp, buf) catch return null;
    return buf[0..n];
}

/// Splits `line` into font runs. Result memory comes from `a`.
pub fn segments(a: Allocator, st: *State, line: []const u8) Allocator.Error!Result {
    var out: std.ArrayList(Segment) = .empty;
    var buf: std.ArrayList(u8) = .empty;
    var run_font = st.font;
    var continued = false;

    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        if (c != '\\') {
            try buf.append(a, c);
            i += 1;
            continue;
        }
        i += 1;
        if (i >= line.len) break;
        const e = line[i];
        i += 1;
        switch (e) {
            'f' => {
                const nm = readName(line[i..]) orelse break;
                i += nm.used;
                try flush(a, &out, &buf, run_font);
                if (std.mem.eql(u8, nm.name, "P")) {
                    st.font = st.prev;
                } else if (Font.fromName(nm.name)) |f| {
                    st.setFont(f);
                }
                run_font = st.font;
            },
            '-' => try buf.append(a, '-'),
            'e', '\\' => try buf.append(a, '\\'),
            '.' => try buf.append(a, '.'),
            '\'' => try buf.append(a, '\''),
            '`' => try buf.append(a, '`'),
            ' ', '~' => try buf.appendSlice(a, "\u{00a0}"),
            '&', '|', '^', '/', ',', ':', '%', '!', '?' => {},
            '"' => i = line.len, // comment to the end of the line
            'c' => {
                if (i >= line.len) continued = true;
            },
            '(', '[' => {
                const nm = readName(line[i - 1 ..]) orelse break;
                i += nm.used - 1;
                var ub: [4]u8 = undefined;
                if (special(nm.name)) |t| {
                    try buf.appendSlice(a, t);
                } else if (unicodeName(nm.name, &ub)) |t| {
                    try buf.appendSlice(a, t);
                }
            },
            '*' => {
                const nm = readName(line[i..]) orelse break;
                i += nm.used;
                if (st.strings.get(nm.name)) |v| {
                    try buf.appendSlice(a, v);
                } else if (builtinString(nm.name)) |v| {
                    try buf.appendSlice(a, v);
                }
            },
            'n', '$' => {
                // Number registers and macro arguments: not supported, dropped.
                const nm = readName(line[i..]) orelse break;
                i += nm.used;
            },
            's' => {
                // Size change: \s0, \s+2, \s-1, \s12, \s(12
                if (i < line.len and (line[i] == '+' or line[i] == '-')) i += 1;
                if (i < line.len and line[i] == '(') i += 1;
                var digits: usize = 0;
                while (i < line.len and std.ascii.isDigit(line[i]) and digits < 2) : (digits += 1) i += 1;
            },
            'm', 'M', 'k', 'z', 'Z', 'b', 'o', 'w', 'X', 'v', 'h', 'l', 'L', 'D', 'H', 'S', 'C', 'N', 'R', 'x', 'p', 'r', 'u', 'd', 't', 'a' => {
                // Drawing, motion and other typesetting escapes with a quoted
                // or named argument. Skip the argument so it is not printed.
                if (i < line.len and (line[i] == '\'')) {
                    const end = std.mem.indexOfScalarPos(u8, line, i + 1, '\'') orelse line.len - 1;
                    i = end + 1;
                } else if (i < line.len and line[i] == '[') {
                    const end = std.mem.indexOfScalarPos(u8, line, i, ']') orelse line.len - 1;
                    i = end + 1;
                }
            },
            else => try buf.append(a, e),
        }
    }
    try flush(a, &out, &buf, run_font);
    return .{ .segments = out.items, .continued = continued };
}

fn flush(a: Allocator, out: *std.ArrayList(Segment), buf: *std.ArrayList(u8), font: Font) Allocator.Error!void {
    if (buf.items.len == 0) return;
    try out.append(a, .{ .text = try a.dupe(u8, buf.items), .font = font });
    buf.clearRetainingCapacity();
}

/// The text of a line with no font information.
pub fn plain(a: Allocator, st: *State, line: []const u8) Allocator.Error![]u8 {
    const r = try segments(a, st, line);
    var out: std.ArrayList(u8) = .empty;
    for (r.segments) |s| try out.appendSlice(a, s.text);
    return out.items;
}

test "fonts, specials and drops" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var st: State = .{};
    const r = try segments(a, &st, "a \\fBbold\\fR \\(em \\-x\\&y \\e \\s-1small\\s0 \\[u00e9]");
    try std.testing.expectEqual(@as(usize, 3), r.segments.len);
    try std.testing.expect(r.segments[1].font.bold);
    try std.testing.expectEqualStrings("bold", r.segments[1].text);
    try std.testing.expectEqualStrings(" \u{2014} -xy \\ small \u{00e9}", r.segments[2].text);
}

test "\\fP returns to the previous font and fonts persist across lines" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var st: State = .{};
    _ = try segments(a, &st, "\\fIit\\fB");
    try std.testing.expect(st.font.bold);
    _ = try segments(a, &st, "x\\fP");
    try std.testing.expect(st.font.italic and !st.font.bold);
}

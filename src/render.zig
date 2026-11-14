//! Turning a page into terminal text. One renderer for every format: the
//! readers build an `md.Node` tree and md-zig writes the text.

const std = @import("std");
const md = @import("md");
const gtroff = @import("gtroff");
const Allocator = std.mem.Allocator;
const Format = @import("format.zig").Format;
const theme = @import("theme.zig");

pub const Options = struct {
    width: usize = 80,
    /// ANSI styles, in the dkman color theme (see `theme.zig`).
    color: bool = false,
    /// Only ASCII characters: lines and bullets are drawn with `-`, `|`, `*`
    /// and typographic characters are replaced by plain ones.
    ascii: bool = false,
    /// Pad wrapped lines of man(7) and mdoc(7) pages to the right margin, as
    /// nroff does. Markdown and plain text are never justified.
    justify: bool = true,
    /// groff's header and footer lines (name, manual, source, date) on man(7)
    /// and mdoc(7) pages.
    frame: bool = true,
    /// HTML instead of terminal text (`.plain` pages become a `<pre>` block).
    html: bool = false,
};

pub const Error = md.ParseError || Allocator.Error;

/// The page as a document tree, for callers that draw it themselves (a GUI
/// viewer) or write HTML. `.plain` has no tree: wrap the text yourself.
/// The caller owns the result and calls `deinit`.
pub fn parse(gpa: Allocator, format: Format, content: []const u8) Error!md.Document {
    return switch (format) {
        .markdown => md.Document.parse(gpa, content, .{ .extensions = md.Extensions.all }),
        .man => gtroff.parseMan(gpa, content),
        .mdoc => gtroff.parseMdoc(gpa, content),
        .plain => md.Document.parse(gpa, "", .{}),
    };
}

/// The page as terminal text; the caller owns the result.
pub fn render(gpa: Allocator, format: Format, content: []const u8, options: Options) Error![]u8 {
    if (format == .plain) {
        if (!options.html) return gpa.dupe(u8, content);
        return plainHtml(gpa, content);
    }
    var doc = try parse(gpa, format, content);
    defer doc.deinit();
    if (options.html) return doc.toHtmlAlloc(gpa);
    // Always drawn with styles, which keeps headings and emphasis free of
    // Markdown markers; without color the escape sequences are removed again,
    // leaving plain text like groff's `nroff -man | col -b`.
    const body = try doc.toTextAlloc(gpa, .{
        .width = options.width,
        .color = true,
        .unicode = !options.ascii,
        .justify = options.justify and (format == .man or format == .mdoc),
        .tight_headings = format == .man or format == .mdoc,
    });
    defer gpa.free(body);
    // man(7) and mdoc(7) pages get groff's header and footer lines.
    const framed: ?[]u8 = if (options.frame and options.width >= 40 and (format == .man or format == .mdoc)) blk: {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const f = (try frameOf(arena_state.allocator(), format, content)) orelse break :blk null;
        break :blk try addFrame(gpa, body, f, options.width - 1);
    } else null;
    defer if (framed) |f| gpa.free(f);
    const drawn = framed orelse body;
    const text = if (options.ascii) try asciify(gpa, drawn) else drawn;
    defer if (options.ascii) gpa.free(text);
    if (!options.color) return stripEscapes(gpa, text);
    return theme.apply(gpa, text);
}

// ---------------------------------------------------------- page header, footer

/// What groff prints at the top and bottom of a man page: the page name and
/// section on both sides of the top line, with the manual's name between them;
/// at the bottom the source (left), the date (middle) and the page name again.
const Frame = struct {
    title: []const u8,
    section: []const u8,
    manual: []const u8,
    left: []const u8,
    middle: []const u8,
};

/// The manual's name for a section, as man(7) macros print it when the page
/// does not give one.
fn manualName(section: []const u8) []const u8 {
    if (section.len == 0) return "General Commands Manual";
    return switch (section[0]) {
        '1' => "General Commands Manual",
        '2' => "System Calls Manual",
        '3' => "Library Functions Manual",
        '4' => "Kernel Interfaces Manual",
        '5' => "File Formats Manual",
        '6' => "Games Manual",
        '7' => "Miscellaneous Information Manual",
        '8' => "System Manager's Manual",
        '9' => "Kernel Developer's Manual",
        else => "General Commands Manual",
    };
}

/// Splits the arguments of a macro line on blanks; double quotes group words.
/// A few roff escapes that only decorate (fonts) are removed, `\-` is `-`.
fn macroArgs(arena: Allocator, line: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < line.len) {
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
        if (i >= line.len) break;
        var word: std.ArrayList(u8) = .empty;
        var quoted = false;
        if (line[i] == '"') {
            quoted = true;
            i += 1;
        }
        while (i < line.len) : (i += 1) {
            const c = line[i];
            if (quoted and c == '"') {
                i += 1;
                break;
            }
            if (!quoted and (c == ' ' or c == '\t')) break;
            if (c == '\\' and i + 1 < line.len) {
                const e = line[i + 1];
                if (e == '-' or e == ' ' or e == '~') {
                    try word.append(arena, if (e == '-') '-' else ' ');
                    i += 1;
                } else if (e == 'f' and i + 2 < line.len) {
                    i += 2;
                } else try word.append(arena, c);
                continue;
            }
            try word.append(arena, c);
        }
        try out.append(arena, word.items);
    }
    return out.items;
}

fn restOfLine(line: []const u8, macro: []const u8) []const u8 {
    return std.mem.trim(u8, line[macro.len..], " \t");
}

/// The header and footer fields of a page, from its `.TH` line (man) or its
/// `.Dt`, `.Os` and `.Dd` lines (mdoc). Null when the source has none.
fn frameOf(arena: Allocator, format: Format, content: []const u8) Allocator.Error!?Frame {
    var th: ?[]const []const u8 = null;
    var dt: ?[]const []const u8 = null;
    var os: []const u8 = "";
    var dd: []const u8 = "";
    var lines = std.mem.splitScalar(u8, content, '\n');
    var seen: usize = 0;
    while (lines.next()) |raw| : (seen += 1) {
        if (seen > 400) break;
        const line = std.mem.trimEnd(u8, raw, "\r");
        switch (format) {
            .man => if (th == null and std.mem.startsWith(u8, line, ".TH ")) {
                th = try macroArgs(arena, line[4..]);
                break;
            },
            .mdoc => {
                if (dt == null and std.mem.startsWith(u8, line, ".Dt ")) dt = try macroArgs(arena, line[4..]);
                if (std.mem.startsWith(u8, line, ".Os")) os = restOfLine(line, ".Os");
                if (std.mem.startsWith(u8, line, ".Dd")) dd = restOfLine(line, ".Dd");
            },
            else => return null,
        }
    }
    const nth = th orelse {
        const d = dt orelse return null;
        if (d.len < 2) return null;
        // `$Mdocdate: July 2 2017 $` is the date of the RCS keyword.
        var date = dd;
        if (std.mem.startsWith(u8, date, "$Mdocdate:")) {
            date = std.mem.trim(u8, date["$Mdocdate:".len..], " $");
        }
        return .{ .title = d[0], .section = d[1], .manual = manualName(d[1]), .left = os, .middle = date };
    };
    if (nth.len < 2) return null;
    return .{
        .title = nth[0],
        .section = nth[1],
        .manual = if (nth.len > 4 and nth[4].len > 0) nth[4] else manualName(nth[1]),
        .left = if (nth.len > 3) nth[3] else "",
        .middle = if (nth.len > 2) nth[2] else "",
    };
}

/// Columns of `s`: its characters (code points), which is right for the
/// plain text of a page header.
fn cols(s: []const u8) usize {
    var n: usize = 0;
    for (s) |c| {
        if (c & 0xc0 != 0x80) n += 1;
    }
    return n;
}

/// A line of `width` columns with `left` at the start, `right` at the end and
/// `middle` centred; text that would overlap is separated by one space.
fn threeParts(arena: Allocator, width: usize, left: []const u8, middle: []const u8, right: []const u8) Allocator.Error![]u8 {
    const lw = cols(left);
    const mw = cols(middle);
    const rw = cols(right);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, left);
    var col = lw;
    const centre_at = @max(if (width > mw) (width - mw + 1) / 2 else 0, lw + @intFromBool(lw > 0 and mw > 0));
    if (mw > 0) {
        try out.appendNTimes(arena, ' ', centre_at -| col);
        try out.appendSlice(arena, middle);
        col = @max(col, centre_at) + mw;
    }
    const right_at = @max(if (width > rw) width - rw else 0, col + @intFromBool(col > 0));
    try out.appendNTimes(arena, ' ', right_at -| col);
    try out.appendSlice(arena, right);
    return out.items;
}

/// `drawn` with its title line replaced by groff's header line and a footer
/// line added. `width` is the line length (the terminal width less one, as
/// groff has it).
fn addFrame(gpa: Allocator, drawn: []const u8, frame: Frame, width: usize) Allocator.Error![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const name = try std.fmt.allocPrint(a, "{s}({s})", .{ frame.title, frame.section });
    const header = try threeParts(a, width, name, frame.manual, name);
    const footer = try threeParts(a, width, frame.left, frame.middle, name);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, header);
    // The drawn text starts with its own title line; the header replaces it.
    const rest = if (std.mem.findScalar(u8, drawn, '\n')) |nl| drawn[nl..] else "\n";
    try out.appendSlice(gpa, rest);
    if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(gpa, '\n');
    try out.append(gpa, '\n');
    try out.appendSlice(gpa, footer);
    try out.append(gpa, '\n');
    return out.toOwnedSlice(gpa);
}

/// Replaces common non-ASCII characters (dashes, quotes, bullets, no-break
/// spaces, ...) by ASCII ones and every other code point by `?`. Escape
/// sequences pass through.
pub fn asciify(gpa: Allocator, text: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, text.len);
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c < 0x80) {
            try out.append(gpa, c);
            i += 1;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(c) catch 1;
        const end = @min(i + len, text.len);
        const cp = std.unicode.utf8Decode(text[i..end]) catch 0xfffd;
        i = end;
        const rep: []const u8 = switch (cp) {
            0x2010, 0x2011, 0x2012, 0x2013, 0xad => "-",
            0x2014, 0x2015 => "--",
            0x2018, 0x2019, 0x201a, 0x2032 => "'",
            0x201c, 0x201d, 0x201e, 0x2033 => "\"",
            0x2022, 0x2023, 0x25cf, 0x25e6, 0xb7 => "o",
            0x2026 => "...",
            0xa0, 0x2002, 0x2003, 0x2009, 0x202f => " ",
            0x2190 => "<-",
            0x2192 => "->",
            0xa9 => "(C)",
            0xae => "(R)",
            0xd7 => "x",
            0x2500, 0x2501 => "-",
            0x2502, 0x2503 => "|",
            0x250c, 0x2510, 0x2514, 0x2518, 0x251c, 0x2524, 0x252c, 0x2534, 0x253c => "+",
            else => "?",
        };
        try out.appendSlice(gpa, rep);
    }
    return out.toOwnedSlice(gpa);
}

fn plainHtml(gpa: Allocator, content: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "<pre>");
    for (content) |c| switch (c) {
        '<' => try out.appendSlice(gpa, "&lt;"),
        '>' => try out.appendSlice(gpa, "&gt;"),
        '&' => try out.appendSlice(gpa, "&amp;"),
        else => try out.append(gpa, c),
    };
    try out.appendSlice(gpa, "</pre>\n");
    return out.toOwnedSlice(gpa);
}

/// Copy of `text` without ANSI escape sequences (`ESC [ ... final byte`).
pub fn stripEscapes(gpa: Allocator, text: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, text.len);
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '[') {
            i += 2;
            while (i < text.len and (text[i] < 0x40 or text[i] > 0x7e)) i += 1;
            i += 1;
            continue;
        }
        out.appendAssumeCapacity(text[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

test "markdown and plain pages render" {
    const t = std.testing;
    const out = try render(t.allocator, .markdown, "# Title\n\nsome *text*\n", .{});
    defer t.allocator.free(out);
    try t.expect(std.mem.find(u8, out, "Title") != null);
    const raw = try render(t.allocator, .plain, "as is\n", .{});
    defer t.allocator.free(raw);
    try t.expectEqualStrings("as is\n", raw);
    const man = try render(t.allocator, .man, ".TH A 1\n.SH NAME\na \\- thing\n", .{});
    defer t.allocator.free(man);
    try t.expect(std.mem.find(u8, man, "a - thing") != null);
    const mdoc = try render(t.allocator, .mdoc, ".Dd today\n.Dt A 1\n.Sh NAME\n.Nm a\n.Nd a thing\n", .{});
    defer t.allocator.free(mdoc);
    try t.expect(std.mem.find(u8, mdoc, "a \u{2014} a thing") != null);
}

test "stripEscapes" {
    const out = try stripEscapes(std.testing.allocator, "\x1b[1;33mNAME\x1b[0m x\x1b[K");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("NAME x", out);
}

test "asciify" {
    const out = try asciify(std.testing.allocator, "a \u{2014} \u{201c}b\u{201d}\u{2026} \u{e9}");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("a -- \"b\"... ?", out);
}

test "html output" {
    const t = std.testing;
    const out = try render(t.allocator, .man, ".TH A 1\n.SH NAME\na \\- b\n", .{ .html = true });
    defer t.allocator.free(out);
    try t.expect(std.mem.find(u8, out, "<h") != null);
    const raw = try render(t.allocator, .plain, "a < b & c\n", .{ .html = true });
    defer t.allocator.free(raw);
    try t.expectEqualStrings("<pre>a &lt; b &amp; c\n</pre>\n", raw);
}

test "header and footer fields of man and mdoc pages" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const t = std.testing;
    const m = (try frameOf(a, .man, ".\\\" c\n.TH \"my\\-tool\" 8 \"June 2026\" \"tools 1.2\" \"Admin Manual\"\n.SH NAME\n")).?;
    try t.expectEqualStrings("my-tool", m.title);
    try t.expectEqualStrings("Admin Manual", m.manual);
    try t.expectEqualStrings("tools 1.2", m.left);
    try t.expectEqualStrings("June 2026", m.middle);
    // No manual given: the section's.
    const n = (try frameOf(a, .man, ".TH ls 3\n")).?;
    try t.expectEqualStrings("Library Functions Manual", n.manual);
    const d = (try frameOf(a, .mdoc, ".Dd $Mdocdate: July 2 2017 $\n.Dt FOO 1\n.Os Debian\n")).?;
    try t.expectEqualStrings("FOO", d.title);
    try t.expectEqualStrings("Debian", d.left);
    try t.expectEqualStrings("July 2 2017", d.middle);
    try t.expect((try frameOf(a, .man, "no macros here\n")) == null);
}

test "header and footer layout matches groff" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const t = std.testing;
    // groff, 80 columns: line length 79, manual name centred.
    const head = try threeParts(a, 79, "LS(1)", "General Commands Manual", "LS(1)");
    try t.expectEqualStrings("LS(1)                       General Commands Manual                       LS(1)", head);
    const foot = try threeParts(a, 79, "", "2026-09-03", "LS(1)");
    try t.expectEqualStrings("                                   2026-09-03                             LS(1)", foot);
    const both = try threeParts(a, 79, "Linux man-pages 6.17", "2026-02-08", "printf(3)");
    try t.expectEqualStrings("Linux man-pages 6.17               2026-02-08                         printf(3)", both);
    // Long left text is not overwritten.
    try t.expectEqualStrings("a-very-long-source-name-indeed 2026 x(1)", try threeParts(a, 30, "a-very-long-source-name-indeed", "2026", "x(1)"));
}

test "a page gets header and footer lines" {
    const t = std.testing;
    const out = try render(t.allocator, .man, ".TH FOO 1 \"2026-01-02\" \"foo 1.0\"\n.SH NAME\nfoo \\- a tool\n", .{ .width = 60 });
    defer t.allocator.free(out);
    var lines = std.mem.splitScalar(u8, out, '\n');
    try t.expectEqualStrings("FOO(1)            General Commands Manual            FOO(1)", lines.next().?);
    try t.expectEqualStrings("", lines.next().?);
    try t.expectEqualStrings("NAME", lines.next().?);
    try t.expectEqualStrings("       foo - a tool", lines.next().?);
    try t.expectEqualStrings("", lines.next().?);
    try t.expectEqualStrings("foo 1.0                  2026-01-02                  FOO(1)", lines.next().?);
}

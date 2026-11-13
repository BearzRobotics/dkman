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
    const drawn = try doc.toTextAlloc(gpa, .{ .width = options.width, .color = true, .unicode = !options.ascii });
    defer gpa.free(drawn);
    const text = if (options.ascii) try asciify(gpa, drawn) else drawn;
    defer if (options.ascii) gpa.free(text);
    if (!options.color) return stripEscapes(gpa, text);
    return theme.apply(gpa, text);
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

//! Deciding how a page file is written.

const std = @import("std");

pub const Format = enum {
    markdown,
    /// Classic man(7) macros.
    man,
    /// BSD mdoc(7) macros.
    mdoc,
    /// Anything else: shown as it is.
    plain,
};

/// The file name without a trailing `.gz`.
pub fn withoutGz(path: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, path, ".gz")) path[0 .. path.len - 3] else path;
}

/// Decides from the file name and the (decompressed) text. The name wins for
/// Markdown; roff is recognised by its first macro line.
pub fn detect(path: []const u8, content: []const u8) Format {
    const p = withoutGz(path);
    if (std.mem.endsWith(u8, p, ".md") or std.mem.endsWith(u8, p, ".markdown")) return .markdown;

    var lines = std.mem.splitScalar(u8, content, '\n');
    var checked: usize = 0;
    while (lines.next()) |line| : (checked += 1) {
        if (checked >= 200) break;
        const l = std.mem.trimEnd(u8, line, "\r");
        if (l.len == 0) continue;
        // Comments and blank macro lines come first in many pages.
        if (std.mem.startsWith(u8, l, ".\\\"") or std.mem.startsWith(u8, l, "'\\\"") or std.mem.startsWith(u8, l, "\\\"") or std.mem.eql(u8, l, ".")) continue;
        // A line that starts with a backslash is a continuation or an escape
        // comment (some generators begin a page with a lone `\`).
        if (l[0] == '\\') continue;
        if (l[0] != '.' and l[0] != '\'') return .plain;
        // Any other macro line means classic man(7)/roff.
        const macro = std.mem.trimStart(u8, l[1..], " \t");
        if (startsMacro(macro, "Dd") or startsMacro(macro, "Dt") or startsMacro(macro, "Os")) return .mdoc;
        return .man;
    }
    return .plain;
}

fn startsMacro(s: []const u8, name: []const u8) bool {
    return std.mem.startsWith(u8, s, name) and (s.len == name.len or s[name.len] == ' ' or s[name.len] == '\t');
}

test "detect by name and content" {
    const t = std.testing;
    try t.expectEqual(Format.markdown, detect("a.1.md", ".TH x 1"));
    try t.expectEqual(Format.markdown, detect("a.1.md.gz", ""));
    try t.expectEqual(Format.man, detect("a.1", ".\\\" comment\n.TH A 1\n.SH NAME\n"));
    try t.expectEqual(Format.mdoc, detect("a.1", ".Dd $Mdocdate$\n.Dt A 1\n"));
    try t.expectEqual(Format.mdoc, detect("a.1", ".\\\" c\n.Dd January 1, 2026\n"));
    try t.expectEqual(Format.man, detect("a.1", "\\\n.\\\" generated\n.TH A 1\n"));
    try t.expectEqual(Format.plain, detect("a.txt", "A NAME\n    text\n"));
    try t.expectEqual(Format.plain, detect("a", ""));
}

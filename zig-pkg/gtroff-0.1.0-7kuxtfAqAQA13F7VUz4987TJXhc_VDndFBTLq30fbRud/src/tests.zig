const std = @import("std");
const gtroff = @import("root.zig");
const testing = std.testing;

fn text(src: []const u8) ![]u8 {
    var doc = try gtroff.parseMan(testing.allocator, src);
    defer doc.deinit();
    return doc.toTextAlloc(testing.allocator, .{ .width = 60 });
}

test "a small page" {
    const out = try text(
        \\.\" comment
        \\.TH LS 1 "June 2026" "tools"
        \\.SH NAME
        \\ls \- list \fBdirectory\fR contents
        \\.SH SYNOPSIS
        \\.B ls
        \\.RI [ option ]...
        \\.SH OPTIONS
        \\.TP
        \\.BR \-a ", " \-\-all
        \\do not ignore entries starting with .
        \\.TP
        \\.B \-l
        \\use a long listing format
        \\.PP
        \\After the list.
        \\
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\# LS(1)
        \\
        \\## NAME
        \\
        \\ls - list **directory** contents
        \\
        \\## SYNOPSIS
        \\
        \\**ls** [_option_]...
        \\
        \\## OPTIONS
        \\
        \\**-a**, **--all**
        \\    do not ignore entries starting with .
        \\
        \\**-l**
        \\    use a long listing format
        \\
        \\After the list.
        \\
    , out);
}

test "code blocks, bullets, indents, links and conditionals" {
    const out = try text(
        \\.SH EXAMPLES
        \\.nf
        \\$ ls \-l
        \\  total 0
        \\.fi
        \\.IP \(bu 2
        \\first
        \\.IP \(bu 2
        \\second
        \\.RS
        \\.PP
        \\indented
        \\.RE
        \\.if n .SS Terminal only
        \\.if t .SS Typeset only
        \\.ie n plain terminal
        \\.el typeset
        \\.if \n(.g \{\
        \\.SS Skipped block
        \\.\}
        \\see
        \\.UR http://example.com
        \\the site
        \\.UE .
        \\
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\## EXAMPLES
        \\
        \\    $ ls -l
        \\      total 0
        \\
        \\• first
        \\• second
        \\
        \\│ indented
        \\
        \\Terminal only
        \\
        \\plain terminal see the site <http://example.com>.
        \\
    , out);
}

test "headings without arguments take the next line; \\c joins lines" {
    const out = try text(".SH\nSEE ALSO\nfoo\\c\nbar\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("## SEE ALSO\n\nfoobar\n", out);
}

test "malformed input does not crash" {
    const inputs = [_][]const u8{
        ".TH",         ".SH \"unterminated", ".TP\n.TP\n.TP", ".RE\n.RE", ".if n \\{\\\n.SH x", ".de X\nnever ends",
        "\\",          "\\f",                "\\(",           "\\[",      "\\[u",               ".nf\nopen",
        ".TS\nrow\tx", ".UR\n.UE",           ".IP",           ".\\\"",    "\\s",                "\\*",
    };
    for (inputs) |src| {
        const out = try text(src);
        testing.allocator.free(out);
    }
}

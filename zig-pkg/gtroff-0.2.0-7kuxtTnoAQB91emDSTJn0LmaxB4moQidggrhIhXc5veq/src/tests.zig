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

fn mdocText(src: []const u8) ![]u8 {
    var doc = try gtroff.parseMdoc(testing.allocator, src);
    defer doc.deinit();
    return doc.toTextAlloc(testing.allocator, .{ .width = 70 });
}

test "mdoc: prologue, name, synopsis, inline macros" {
    const out = try mdocText(
        \\.Dd June 1, 2026
        \\.Dt LS 1
        \\.Os
        \\.Sh NAME
        \\.Nm ls
        \\.Nd list directory contents
        \\.Sh SYNOPSIS
        \\.Nm
        \\.Op Fl al
        \\.Op Fl Fl color Ns = Ns Ar when
        \\.Op Ar file ...
        \\.Sh DESCRIPTION
        \\The
        \\.Nm
        \\utility lists files, see
        \\.Xr stat 2 ,
        \\and
        \\.Pa /etc/passwd .
        \\.Pp
        \\Second
        \\.Dq quoted text
        \\paragraph.
        \\
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\# LS(1)
        \\
        \\## NAME
        \\
        \\**ls** — list directory contents
        \\
        \\## SYNOPSIS
        \\
        \\**ls** [**-al**] [**--color**=_when_] [_file ..._]
        \\
        \\## DESCRIPTION
        \\
        \\The **ls** utility lists files, see stat(2), and _/etc/passwd_.
        \\
        \\Second “quoted text” paragraph.
        \\
    , out);
}

test "mdoc: lists, displays, functions and references" {
    const out = try mdocText(
        \\.Dd today
        \\.Dt T 3
        \\.Os
        \\.Sh OPTIONS
        \\.Bl -tag -width Ds
        \\.It Fl a
        \\show all
        \\.It Fl b Ar n
        \\bytes
        \\.El
        \\.Bl -bullet
        \\.It
        \\one
        \\.It
        \\two
        \\.El
        \\.Bd -literal
        \\$ cmd  arg
        \\.Ed
        \\.Dl $ run it
        \\.Sh SEE ALSO
        \\.Fn open "const char *path" "int flags"
        \\.Rs
        \\.%A A. Author
        \\.%T A Title
        \\.%D 1999
        \\.Re
        \\.Sh STANDARDS
        \\.St -p1003.1-2008
        \\
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\# T(3)
        \\
        \\## OPTIONS
        \\
        \\**-a**
        \\    show all
        \\
        \\**-b** _n_
        \\    bytes
        \\
        \\• one
        \\• two
        \\
        \\    $ cmd  arg
        \\
        \\    $ run it
        \\
        \\## SEE ALSO
        \\
        \\**open**(_const char *path_, _int flags_)
        \\
        \\A. Author, A Title, 1999.
        \\
        \\## STANDARDS
        \\
        \\IEEE Std 1003.1-2008 (“POSIX.1”)
        \\
    , out);
}

test "mdoc: malformed input does not crash" {
    const inputs = [_][]const u8{
        ".Dt",                ".Sh",                    ".Bl", ".It", ".El\n.El", ".Bl -column\n.It a Ta b\n.El", ".Xo\n.Fl a", ".Xc",      ".Op",      ".Fn",      ".Fo f\n.Fa x\n.Fc",
        ".Bd -literal\nopen", ".Rs\n.%A",               ".Re", ".Pf", ".Lk",      ".Ar Fl Ar Fl",                 ".St",        ".Nm\n.Nd", ".Ex -std", ".Rv -std", "\\",
        ".Dq\n.Dq .",         ".Xo foo\n.Xo\n.Xc\n.Xc",
    };
    for (inputs) |src| {
        const out = try mdocText(src);
        testing.allocator.free(out);
    }
}

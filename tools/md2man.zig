//! Build-time tool: turns a dkman manual page written in Markdown into man(7)
//! source, so the installed `dkman.1` can be read by any man program.
//!
//!     md2man INPUT.md OUTPUT.1 TITLE SECTION SOURCE
//!
//! It handles what docs/manpages/*.md use: headings (`#` is a section, `##` a
//! subsection), paragraphs, bullet lists, definition lists (`term` then `: text`),
//! code blocks, inline code, emphasis, strong text and links.

const std = @import("std");
const md = @import("md");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Node = md.Node;

const Writer = struct {
    gpa: Allocator,
    out: std.ArrayList(u8) = .empty,
    /// True at the start of an output line, where `.` and `'` would start a macro.
    at_line_start: bool = true,

    fn raw(w: *Writer, s: []const u8) Allocator.Error!void {
        try w.out.appendSlice(w.gpa, s);
        if (s.len > 0) w.at_line_start = s[s.len - 1] == '\n';
    }

    /// Text with roff's special characters escaped.
    fn text(w: *Writer, s: []const u8) Allocator.Error!void {
        for (s) |c| {
            if (w.at_line_start and (c == '.' or c == '\'')) try w.out.appendSlice(w.gpa, "\\&");
            switch (c) {
                '\\' => try w.out.appendSlice(w.gpa, "\\e"),
                '-' => try w.out.appendSlice(w.gpa, "\\-"),
                else => try w.out.append(w.gpa, c),
            }
            w.at_line_start = c == '\n';
        }
    }

    fn inlines(w: *Writer, parent: *Node) Allocator.Error!void {
        var child = parent.first_child;
        while (child) |n| : (child = n.next) try w.inline1(n);
    }

    fn inline1(w: *Writer, n: *Node) Allocator.Error!void {
        switch (n.kind) {
            .text => try w.text(n.literal),
            .softbreak => try w.raw("\n"),
            .linebreak => try w.raw("\n.br\n"),
            .code => {
                try w.raw("\\fB");
                try w.text(n.literal);
                try w.raw("\\fR");
            },
            .strong => {
                try w.raw("\\fB");
                try w.inlines(n);
                try w.raw("\\fR");
            },
            .emph => {
                try w.raw("\\fI");
                try w.inlines(n);
                try w.raw("\\fR");
            },
            .link => {
                try w.inlines(n);
                if (n.literal.len > 0) {
                    try w.raw(" <");
                    try w.text(n.literal);
                    try w.raw(">");
                }
            },
            else => try w.inlines(n),
        }
    }

    /// A line break before text if the output is not at the start of a line.
    fn newline(w: *Writer) Allocator.Error!void {
        if (!w.at_line_start) try w.raw("\n");
    }

    fn blocks(w: *Writer, parent: *Node, first_is_tagged: bool) Allocator.Error!void {
        var child = parent.first_child;
        var first = true;
        while (child) |n| : (child = n.next) {
            try w.block(n, first and first_is_tagged);
            first = false;
        }
    }

    /// `joined` is true for the first paragraph of an item or definition: its
    /// macro (.IP/.TP) was already written, so no .PP.
    fn block(w: *Writer, n: *Node, joined: bool) Allocator.Error!void {
        switch (n.kind) {
            .heading => {
                try w.newline();
                try w.raw(if (n.level == 1) ".SH \"" else ".SS \"");
                try w.inlines(n);
                try w.raw("\"\n");
            },
            .paragraph => {
                try w.newline();
                if (!joined) try w.raw(".PP\n");
                try w.inlines(n);
                try w.raw("\n");
            },
            .code_block => {
                try w.newline();
                try w.raw(".PP\n.RS 4\n.nf\n");
                try w.text(n.literal);
                try w.newline();
                try w.raw(".fi\n.RE\n");
            },
            .list => {
                var item = n.first_child;
                while (item) |it| : (item = it.next) {
                    try w.newline();
                    try w.raw(".IP \\(bu 2\n");
                    try w.blocks(it, true);
                }
            },
            .deflist => {
                var child = n.first_child;
                while (child) |c| : (child = c.next) switch (c.kind) {
                    .deflist_term => {
                        try w.newline();
                        try w.raw(".TP\n");
                        try w.inlines(c);
                        try w.raw("\n");
                    },
                    .deflist_def => {
                        // The first paragraph follows the term; later blocks are
                        // indented like it.
                        var blk = c.first_child;
                        var first = true;
                        while (blk) |b| : (blk = b.next) {
                            if (!first and b.kind == .paragraph) try w.raw(".IP\n");
                            try w.block(b, true);
                            first = false;
                        }
                    },
                    else => {},
                };
            },
            .block_quote => {
                try w.newline();
                try w.raw(".RS 4\n");
                try w.blocks(n, false);
                try w.raw(".RE\n");
            },
            .thematic_break => {},
            else => {},
        }
    }
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 6) {
        try Io.File.stderr().writeStreamingAll(io, "usage: md2man INPUT.md OUTPUT.1 TITLE SECTION SOURCE\n");
        return 2;
    }
    const source = try Io.Dir.cwd().readFileAlloc(io, args[1], gpa, .limited(1 << 20));
    defer gpa.free(source);
    var doc = try md.Document.parse(gpa, source, .{ .extensions = md.Extensions.all });
    defer doc.deinit();

    var w: Writer = .{ .gpa = gpa };
    defer w.out.deinit(gpa);
    try w.raw(".\\\" Generated from the Markdown page by tools/md2man.zig; do not edit.\n");
    try w.raw(".TH ");
    try w.text(args[3]);
    try w.raw(" ");
    try w.text(args[4]);
    try w.raw(" \"\" \"");
    try w.text(args[5]);
    try w.raw("\"\n");
    try w.blocks(doc.root, false);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = args[2], .data = w.out.items });
    return 0;
}

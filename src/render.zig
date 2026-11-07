//! Turning a page into terminal text. One renderer for every format: the
//! readers build an `md.Node` tree and md-zig writes the text.

const std = @import("std");
const md = @import("md");
const gtroff = @import("gtroff");
const Allocator = std.mem.Allocator;
const Format = @import("format.zig").Format;

pub const Options = struct {
    width: usize = 80,
    color: bool = false,
};

pub const Error = md.ParseError || Allocator.Error;

/// The page as terminal text; the caller owns the result.
pub fn render(gpa: Allocator, format: Format, content: []const u8, options: Options) Error![]u8 {
    switch (format) {
        .markdown => {
            var doc = try md.Document.parse(gpa, content, .{ .extensions = md.Extensions.all });
            defer doc.deinit();
            return doc.toTextAlloc(gpa, .{ .width = options.width, .color = options.color });
        },
        .man => {
            var doc = try gtroff.parseMan(gpa, content);
            defer doc.deinit();
            return doc.toTextAlloc(gpa, .{ .width = options.width, .color = options.color });
        },
        .mdoc => {
            var doc = try gtroff.parseMdoc(gpa, content);
            defer doc.deinit();
            return doc.toTextAlloc(gpa, .{ .width = options.width, .color = options.color });
        },
        .plain => return gpa.dupe(u8, content),
    }
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

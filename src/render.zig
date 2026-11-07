//! Turning a page into terminal text. One renderer for every format: the
//! readers build an `md.Node` tree and md-zig writes the text.

const std = @import("std");
const md = @import("md");
const Allocator = std.mem.Allocator;
const Format = @import("format.zig").Format;

pub const Options = struct {
    width: usize = 80,
    color: bool = false,
};

pub const Error = error{
    /// The page is roff and no roff reader is linked in yet.
    RoffNotSupported,
} || md.ParseError || Allocator.Error;

/// The page as terminal text; the caller owns the result.
pub fn render(gpa: Allocator, format: Format, content: []const u8, options: Options) Error![]u8 {
    switch (format) {
        .markdown => {
            var doc = try md.Document.parse(gpa, content, .{ .extensions = md.Extensions.all });
            defer doc.deinit();
            return doc.toTextAlloc(gpa, .{ .width = options.width, .color = options.color });
        },
        .man, .mdoc => return error.RoffNotSupported,
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
    try t.expectError(error.RoffNotSupported, render(t.allocator, .man, ".TH A 1\n", .{}));
}

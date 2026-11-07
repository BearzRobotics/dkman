//! gtroff-zig: reads roff manual pages (man(7), later mdoc(7)) into an
//! md-zig tree, so one renderer can show Markdown and man pages alike.

const std = @import("std");
const md = @import("md");
const Allocator = std.mem.Allocator;

pub const escape = @import("escape.zig");
pub const man = @import("man.zig");

/// Parses a man(7) page into an md-zig document (see `man.zig`).
pub const parseMan = man.parse;

test {
    _ = @import("escape.zig");
    _ = @import("man.zig");
    _ = @import("tests.zig");
}

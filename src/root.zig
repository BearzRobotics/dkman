//! dkman as a library: finding manual pages and Markdown documents, reading
//! them (gzip aware), detecting their format and turning them into an
//! `md.Document` or terminal text. The `dkman` program is a thin wrapper.
//!
//! Nothing here reads the environment or prints: callers pass `MANPATH`,
//! the `std.Io` instance and allocators in.

/// The Markdown library `render.parse` builds its documents with, re-exported
/// so a consumer walks them with the very version dkman was built against.
pub const md = @import("md");

pub const paths = @import("paths.zig");
pub const source = @import("source.zig");
pub const format = @import("format.zig");
pub const render = @import("render.zig");
pub const search = @import("search.zig");
pub const theme = @import("theme.zig");

pub const Format = format.Format;
pub const Page = paths.Page;

test {
    _ = paths;
    _ = source;
    _ = format;
    _ = render;
    _ = search;
    _ = theme;
}

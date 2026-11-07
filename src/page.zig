//! Loading one page for display: read the file (or standard input), follow
//! `.so` redirects, and say how it is written.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const paths = @import("paths.zig");
const source = @import("source.zig");
const format = @import("format.zig");
const render = @import("render.zig");

pub const Loaded = struct {
    /// The page text, owned by the caller (allocated with the `gpa` given to `load`).
    bytes: []u8,
    /// Where it was finally read from, after redirects; borrowed.
    path: []const u8,
    format: format.Format,

    pub fn deinit(l: Loaded, gpa: Allocator) void {
        gpa.free(l.bytes);
    }
};

pub const Error = source.Error || error{BrokenRedirect};

/// Reads `path_in` (`-` is standard input) and follows redirects: a page that
/// only says `.so man1/other.1` shows that page. A few hops at most, so a loop
/// of redirects ends.
pub fn load(gpa: Allocator, arena: Allocator, io: Io, dirs: []const []const u8, path_in: []const u8) Error!Loaded {
    var path = path_in;
    var bytes = try read(gpa, io, path);
    errdefer gpa.free(bytes);

    var hops: usize = 0;
    while (paths.soTarget(bytes)) |target| : (hops += 1) {
        if (hops >= 4) break;
        const next = try paths.resolveSo(arena, io, dirs, target) orelse break;
        const loaded = read(gpa, io, next) catch break;
        gpa.free(bytes);
        bytes = loaded;
        path = next;
    }
    if (paths.soTarget(bytes) != null) return error.BrokenRedirect;
    return .{ .bytes = bytes, .path = path, .format = format.detect(path, bytes) };
}

fn read(gpa: Allocator, io: Io, path: []const u8) source.Error![]u8 {
    if (std.mem.eql(u8, path, "-")) {
        var buf: [4096]u8 = undefined;
        var r = Io.File.stdin().reader(io, &buf);
        return r.interface.allocRemaining(gpa, .limited(source.max_bytes)) catch |err| switch (err) {
            error.StreamTooLong => error.PageTooLarge,
            error.OutOfMemory => error.OutOfMemory,
            error.ReadFailed => error.ReadFailed,
        };
    }
    return source.load(gpa, io, path);
}

/// Loads and renders in one step; the caller owns the text.
pub fn renderFile(gpa: Allocator, arena: Allocator, io: Io, dirs: []const []const u8, path: []const u8, opts: render.Options) ![]u8 {
    const page = try load(gpa, arena, io, dirs, path);
    defer page.deinit(gpa);
    return render.render(gpa, page.format, page.bytes, opts);
}

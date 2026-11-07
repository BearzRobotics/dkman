//! Reading a page file into memory, undoing gzip.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;

/// Longest page accepted, after decompression.
pub const max_bytes: usize = 64 * 1024 * 1024;

pub const Error = error{ PageTooLarge, BadGzip, ReadFailed } || Allocator.Error || Io.File.OpenError;

/// Reads `path` (relative to the current directory or absolute). `.gz` files
/// are decompressed. The caller owns the result.
pub fn load(gpa: Allocator, io: Io, path: []const u8) Error![]u8 {
    var file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    return if (std.mem.endsWith(u8, path, ".gz"))
        loadGzip(gpa, &reader.interface)
    else
        reader.interface.allocRemaining(gpa, .limited(max_bytes)) catch |err| switch (err) {
            error.StreamTooLong => error.PageTooLarge,
            error.OutOfMemory => error.OutOfMemory,
            error.ReadFailed => error.ReadFailed,
        };
}

/// Reads everything from `input` and decompresses it as gzip.
pub fn loadGzip(gpa: Allocator, input: *Io.Reader) Error![]u8 {
    var window: [flate.max_window_len]u8 = undefined;
    var dec: flate.Decompress = .init(input, .gzip, &window);
    return dec.reader.allocRemaining(gpa, .limited(max_bytes)) catch |err| switch (err) {
        error.StreamTooLong => error.PageTooLarge,
        error.OutOfMemory => error.OutOfMemory,
        error.ReadFailed => if (dec.err != null) error.BadGzip else error.ReadFailed,
    };
}

test "loadGzip reads gzip data and rejects garbage" {
    const t = std.testing;
    // "hello\n" compressed with gzip.
    const gz = [_]u8{ 0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0xe7, 0x02, 0x00, 0x20, 0x30, 0x3a, 0x36, 0x06, 0x00, 0x00, 0x00 };
    var r: Io.Reader = .fixed(&gz);
    const out = try loadGzip(t.allocator, &r);
    defer t.allocator.free(out);
    try t.expectEqualStrings("hello\n", out);

    var bad: Io.Reader = .fixed("this is not gzip at all");
    try t.expectError(error.BadGzip, loadGzip(t.allocator, &bad));
}

//! Reading a page file into memory, undoing gzip, xz, zstd, bzip2 and lzma.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;

/// Longest page accepted, after decompression.
pub const max_bytes: usize = 64 * 1024 * 1024;

pub const Error = error{ PageTooLarge, BadCompression, DecompressorMissing, ReadFailed } || Allocator.Error || Io.File.OpenError;

/// Compression of a page file, recognised by its first bytes (so a mislabelled
/// file still opens) and, for lzma, which has no magic number, by its name.
pub const Compression = enum {
    none,
    gzip,
    xz,
    zstd,
    bzip2,
    lzma,

    pub fn detect(path: []const u8, head: []const u8) Compression {
        if (std.mem.startsWith(u8, head, &.{ 0x1f, 0x8b })) return .gzip;
        if (std.mem.startsWith(u8, head, &.{ 0xFD, '7', 'z', 'X', 'Z', 0x00 })) return .xz;
        if (std.mem.startsWith(u8, head, &.{ 0x28, 0xB5, 0x2F, 0xFD })) return .zstd;
        if (std.mem.startsWith(u8, head, "BZh")) return .bzip2;
        if (std.mem.endsWith(u8, path, ".lzma")) return .lzma;
        return .none;
    }
};

/// Reads `path` (relative to the current directory or absolute). gzip, xz and
/// zstd are decompressed in process; bzip2 and lzma by the system's `bzip2` and
/// `xz`. The caller owns the result.
pub fn load(gpa: Allocator, io: Io, path: []const u8) Error![]u8 {
    var file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    const head = reader.interface.peek(6) catch |err| switch (err) {
        error.EndOfStream => reader.interface.buffered(),
        error.ReadFailed => return error.ReadFailed,
    };
    return switch (Compression.detect(path, head)) {
        .none => readAll(gpa, &reader.interface),
        .gzip => loadGzip(gpa, &reader.interface),
        .xz => loadXz(gpa, &reader.interface),
        .zstd => loadZstd(gpa, &reader.interface),
        .bzip2 => loadExternal(gpa, io, &.{ "bzip2", "-dc", "--", path }),
        .lzma => loadExternal(gpa, io, &.{ "xz", "-dc", "--format=lzma", "--", path }),
    };
}

fn readAll(gpa: Allocator, input: *Io.Reader) Error![]u8 {
    return input.allocRemaining(gpa, .limited(max_bytes)) catch |err| switch (err) {
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
        error.ReadFailed => if (dec.err != null) error.BadCompression else error.ReadFailed,
    };
}

/// Reads everything from `input` and decompresses it as an xz stream.
pub fn loadXz(gpa: Allocator, input: *Io.Reader) Error![]u8 {
    var dec = std.compress.xz.Decompress.init(input, gpa, &.{}) catch |err| switch (err) {
        error.ReadFailed, error.EndOfStream => return error.ReadFailed,
        else => return error.BadCompression,
    };
    defer dec.deinit();
    return dec.reader.allocRemaining(gpa, .limited(max_bytes)) catch |err| switch (err) {
        error.StreamTooLong => error.PageTooLarge,
        error.OutOfMemory => error.OutOfMemory,
        error.ReadFailed => if (dec.err != null) error.BadCompression else error.ReadFailed,
    };
}

/// Reads everything from `input` and decompresses it as zstd.
pub fn loadZstd(gpa: Allocator, input: *Io.Reader) Error![]u8 {
    const window = std.compress.zstd.default_window_len;
    const buffer = try gpa.alloc(u8, window + std.compress.zstd.block_size_max);
    defer gpa.free(buffer);
    var dec: std.compress.zstd.Decompress = .init(input, buffer, .{ .window_len = window });
    return dec.reader.allocRemaining(gpa, .limited(max_bytes)) catch |err| switch (err) {
        error.StreamTooLong => error.PageTooLarge,
        error.OutOfMemory => error.OutOfMemory,
        error.ReadFailed => if (dec.err != null) error.BadCompression else error.ReadFailed,
    };
}

/// Runs a decompressor that writes the plain text to its standard output.
fn loadExternal(gpa: Allocator, io: Io, argv: []const []const u8) Error![]u8 {
    var child = std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .pipe, .stderr = .ignore }) catch return error.DecompressorMissing;
    var buf: [4096]u8 = undefined;
    var r = child.stdout.?.reader(io, &buf);
    const out = readAll(gpa, &r.interface) catch |err| {
        child.kill(io);
        return err;
    };
    errdefer gpa.free(out);
    const term = child.wait(io) catch return error.BadCompression;
    switch (term) {
        .exited => |code| if (code != 0) return error.BadCompression,
        else => return error.BadCompression,
    }
    return out;
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
    try t.expectError(error.BadCompression, loadGzip(t.allocator, &bad));
}

test "loadXz and loadZstd read their formats and reject garbage" {
    const t = std.testing;
    const xz = [_]u8{ 0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00, 0x00, 0x01, 0x69, 0x22, 0xde, 0x36, 0x04, 0xc0, 0x0a, 0x06, 0x21, 0x01, 0x16, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xaa, 0x30, 0x8e, 0xa6, 0x01, 0x00, 0x05, 0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x0a, 0x00, 0x00, 0x00, 0x20, 0x30, 0x3a, 0x36, 0x00, 0x01, 0x22, 0x06, 0x3e, 0x56, 0x57, 0x6e, 0x90, 0x42, 0x99, 0x0d, 0x01, 0x00, 0x00, 0x00, 0x00, 0x01, 0x59, 0x5a };
    var r: Io.Reader = .fixed(&xz);
    const a = try loadXz(t.allocator, &r);
    defer t.allocator.free(a);
    try t.expectEqualStrings("hello\n", a);

    const zst = [_]u8{ 0x28, 0xb5, 0x2f, 0xfd, 0x04, 0x58, 0x31, 0x00, 0x00, 0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x0a, 0x53, 0x88, 0xbd, 0x91 };
    var r2: Io.Reader = .fixed(&zst);
    const b = try loadZstd(t.allocator, &r2);
    defer t.allocator.free(b);
    try t.expectEqualStrings("hello\n", b);

    var bad: Io.Reader = .fixed("this is not xz at all, nor anything else");
    try t.expectError(error.BadCompression, loadXz(t.allocator, &bad));
}

test "Compression.detect goes by magic bytes" {
    const t = std.testing;
    try t.expectEqual(Compression.xz, Compression.detect("a.1", &.{ 0xFD, '7', 'z', 'X', 'Z', 0 }));
    try t.expectEqual(Compression.zstd, Compression.detect("a.1.gz", &.{ 0x28, 0xB5, 0x2F, 0xFD }));
    try t.expectEqual(Compression.lzma, Compression.detect("a.1.lzma", "x"));
    try t.expectEqual(Compression.none, Compression.detect("a.1", ".TH"));
}

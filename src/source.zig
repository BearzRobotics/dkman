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

/// Largest zstd window accepted: the default limit of the reference decoder
/// (2^27 bytes). A bigger one is `error.BadCompression`.
const zstd_window_max: usize = 1 << 27;

/// The window size a zstd frame needs, from the start of the frame (RFC 8878
/// section 3.1.1.1: magic number, frame header descriptor, then the window
/// descriptor or, for a single-segment frame, the content size). Null when the
/// bytes are not a frame header.
pub fn zstdWindow(head: []const u8) ?u64 {
    if (head.len < 6 or !std.mem.eql(u8, head[0..4], &.{ 0x28, 0xB5, 0x2F, 0xFD })) return null;
    const descriptor = head[4];
    const single_segment = descriptor & 0x20 != 0;
    if (!single_segment) {
        // Window_Descriptor: 3 bits of mantissa, 5 of exponent.
        const w = head[5];
        const base: u64 = @as(u64, 1) << @intCast(10 + (w >> 3));
        return base + (base / 8) * (w & 7);
    }
    // Single segment: the window is the content size, which follows the
    // dictionary id (0, 1, 2 or 4 bytes).
    const dict_len: usize = switch (descriptor & 3) {
        0 => 0,
        1 => 1,
        2 => 2,
        else => 4,
    };
    const fcs_len: usize = switch (descriptor >> 6) {
        0 => 1,
        1 => 2,
        2 => 4,
        else => 8,
    };
    const at = 5 + dict_len;
    if (head.len < at + fcs_len) return null;
    var size: u64 = 0;
    for (head[at .. at + fcs_len], 0..) |byte, i| size |= @as(u64, byte) << @intCast(8 * i);
    if (fcs_len == 2) size += 256;
    return size;
}

/// Reads everything from `input` and decompresses it as zstd.
pub fn loadZstd(gpa: Allocator, input: *Io.Reader) Error![]u8 {
    const head = input.peek(14) catch |err| switch (err) {
        error.EndOfStream => input.buffered(),
        error.ReadFailed => return error.ReadFailed,
    };
    const needed = zstdWindow(head) orelse return error.BadCompression;
    if (needed > zstd_window_max) return error.BadCompression;
    // The decoder's buffer holds the window and one block.
    const window: usize = @max(@as(usize, @intCast(needed)), 4096);
    const buffer = try gpa.alloc(u8, window + std.compress.zstd.block_size_max);
    defer gpa.free(buffer);
    var dec: std.compress.zstd.Decompress = .init(input, buffer, .{ .window_len = @intCast(window) });
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

test "zstd frames with a large declared window and the window size reader" {
    const t = std.testing;
    // `zstd --ultra -22` declares a 128 MiB window even for a tiny input.
    const big = [_]u8{ 0x28, 0xb5, 0x2f, 0xfd, 0x04, 0x88, 0x31, 0x00, 0x00, 0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x0a, 0x53, 0x88, 0xbd, 0x91 };
    try t.expectEqual(@as(?u64, 1 << 27), zstdWindow(&big));
    var r: Io.Reader = .fixed(&big);
    const out = try loadZstd(t.allocator, &r);
    defer t.allocator.free(out);
    try t.expectEqualStrings("hello\n", out);

    // Compressing from a pipe: a 2 MiB window declared.
    const small = [_]u8{ 0x28, 0xb5, 0x2f, 0xfd, 0x04, 0x58, 0x31, 0x00, 0x00, 0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x0a, 0x53, 0x88, 0xbd, 0x91 };
    try t.expectEqual(@as(?u64, 1 << 21), zstdWindow(&small));
    // Compressing a file records its size, and the frame is single-segment:
    // the window is the 6 bytes of content.
    const single = [_]u8{ 0x28, 0xb5, 0x2f, 0xfd, 0x24, 0x06, 0x31, 0x00, 0x00, 0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x0a, 0x53, 0x88, 0xbd, 0x91 };
    try t.expectEqual(@as(?u64, 6), zstdWindow(&single));
    var r3: Io.Reader = .fixed(&single);
    const one = try loadZstd(t.allocator, &r3);
    defer t.allocator.free(one);
    try t.expectEqualStrings("hello\n", one);

    try t.expectEqual(@as(?u64, null), zstdWindow("not zstd at all"));
    try t.expectEqual(@as(?u64, null), zstdWindow(&.{ 0x28, 0xB5 }));
    // A window beyond the limit is refused, not allocated.
    var huge = big;
    huge[5] = 0xF8; // exponent 31: 2 GiB
    var r2: Io.Reader = .fixed(&huge);
    try t.expectError(error.BadCompression, loadZstd(t.allocator, &r2));
}

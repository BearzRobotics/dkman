//! bzip2 decompression: the format of bzip2 1.0.x (`.bz2` files).
//!
//! A stream is the magic `BZh1`..`BZh9` (the digit is the block size in units
//! of 100 000 bytes), then blocks, then an end marker with a CRC of all the
//! blocks. Each block is: move-to-front and zero-run coded symbols, Huffman
//! coded with up to six tables that change every 50 symbols; undoing those
//! gives the Burrows-Wheeler transform of the block, which is inverted with
//! the stored starting position, and the result is run-length decoded (four
//! equal bytes are followed by a repeat count).
//!
//! The block and stream CRCs are checked. The obsolete "randomised" blocks are
//! refused. Concatenated streams are read one after the other, as bzip2 does.
//!
//! Reference: the bzip2 1.0.8 source (`decompress.c`, `huffman.c`,
//! `crctable.c`) and its format description; this is written from that
//! description, not copied from it.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Error = error{
    /// Not a bzip2 stream, or damaged.
    Corrupt,
    /// A CRC does not match.
    BadCrc,
    /// A randomised block (bzip2 0.9.0 and earlier).
    Unsupported,
    /// The output would be longer than the limit.
    TooLarge,
    ReadFailed,
} || Allocator.Error;

const block_magic: u48 = 0x314159265359;
const end_magic: u48 = 0x177245385090;
const max_groups = 6;
const max_selectors = 18002;
const group_size = 50;
const max_code_len = 20;
const max_alpha = 258;

/// bzip2's CRC-32: most significant bit first, polynomial 0x04c11db7.
const crc_table = blk: {
    @setEvalBranchQuota(10_000);
    var t: [256]u32 = undefined;
    for (&t, 0..) |*e, i| {
        var c: u32 = @as(u32, @intCast(i)) << 24;
        for (0..8) |_| c = if (c & 0x8000_0000 != 0) (c << 1) ^ 0x04c1_1db7 else c << 1;
        e.* = c;
    }
    break :blk t;
};

fn crcUpdate(crc: u32, b: u8) u32 {
    return (crc << 8) ^ crc_table[(crc >> 24) ^ b];
}

/// Reads bits, most significant first.
const BitReader = struct {
    input: *Io.Reader,
    bits: u64 = 0,
    n: u7 = 0,

    fn get(r: *BitReader, k: u6) Error!u32 {
        if (k == 0) return 0;
        while (r.n < k) {
            const b = r.input.takeByte() catch |err| switch (err) {
                error.EndOfStream => return error.Corrupt,
                error.ReadFailed => return error.ReadFailed,
            };
            r.bits = (r.bits << 8) | b;
            r.n += 8;
        }
        r.n -= k;
        return @intCast((r.bits >> @intCast(r.n)) & ((@as(u64, 1) << k) - 1));
    }

    fn bit(r: *BitReader) Error!u32 {
        return r.get(1);
    }

    /// Drops the bits left in the current byte.
    fn align_(r: *BitReader) void {
        r.n = 0;
        r.bits = 0;
    }
};

/// Canonical Huffman decoding tables for one coding table (from the code
/// lengths: codes of one length are consecutive, shorter codes come first).
const Table = struct {
    limit: [max_code_len + 2]i32 = undefined,
    base: [max_code_len + 2]i32 = undefined,
    perm: [max_alpha]u16 = undefined,
    min_len: u6 = 0,
    max_len: u6 = 0,

    fn init(lengths: []const u8) Table {
        var t: Table = .{};
        var lo: u8 = 255;
        var hi: u8 = 0;
        for (lengths) |l| {
            lo = @min(lo, l);
            hi = @max(hi, l);
        }
        t.min_len = @intCast(lo);
        t.max_len = @intCast(hi);
        var pp: usize = 0;
        var len: u8 = lo;
        while (len <= hi) : (len += 1) {
            for (lengths, 0..) |l, sym| {
                if (l == len) {
                    t.perm[pp] = @intCast(sym);
                    pp += 1;
                }
            }
        }
        // base[l]: the number of symbols with a length below l.
        var count: [max_code_len + 2]i32 = @splat(0);
        for (lengths) |l| count[l + 1] += 1;
        t.base = @splat(0);
        var acc: i32 = 0;
        for (0..max_code_len + 2) |i| {
            acc += count[i];
            t.base[i] = acc;
        }
        t.limit = @splat(0);
        var vec: i32 = 0;
        len = lo;
        while (len <= hi) : (len += 1) {
            vec += t.base[len + 1] - t.base[len];
            t.limit[len] = vec - 1;
            vec <<= 1;
        }
        len = lo + 1;
        while (len <= hi) : (len += 1) {
            t.base[len] = ((t.limit[len - 1] + 1) << 1) - t.base[len];
        }
        return t;
    }

    fn decode(t: *const Table, r: *BitReader) Error!u16 {
        var len: u6 = t.min_len;
        var code: i32 = @intCast(try r.get(len));
        while (code > t.limit[len]) {
            len += 1;
            if (len > max_code_len) return error.Corrupt;
            code = (code << 1) | @as(i32, @intCast(try r.bit()));
        }
        const idx = code - t.base[len];
        if (idx < 0 or idx >= max_alpha) return error.Corrupt;
        return t.perm[@intCast(idx)];
    }
};

/// Decodes one block into `out`. Returns false at the end of the stream.
fn block(gpa: Allocator, r: *BitReader, level: u32, tt: []u32, out: *std.ArrayList(u8), max_out: usize, combined: *u32) Error!bool {
    const magic: u48 = (@as(u48, try r.get(24)) << 24) | try r.get(24);
    if (magic == end_magic) {
        const stored = try r.get(32);
        if (stored != combined.*) return error.BadCrc;
        return false;
    }
    if (magic != block_magic) return error.Corrupt;
    const block_crc = try r.get(32);
    if (try r.bit() != 0) return error.Unsupported;
    const orig_ptr = try r.get(24);

    // Which byte values occur.
    var seq_to_unseq: [256]u8 = undefined;
    var in_use: usize = 0;
    const groups_used = try r.get(16);
    for (0..16) |i| {
        if (groups_used & (@as(u32, 0x8000) >> @intCast(i)) == 0) continue;
        const bits = try r.get(16);
        for (0..16) |j| {
            if (bits & (@as(u32, 0x8000) >> @intCast(j)) != 0) {
                seq_to_unseq[in_use] = @intCast(i * 16 + j);
                in_use += 1;
            }
        }
    }
    if (in_use == 0) return error.Corrupt;
    const alpha = in_use + 2;
    const eob: u16 = @intCast(in_use + 1);

    // Which coding table is used for each run of 50 symbols (move-to-front coded).
    const n_groups = try r.get(3);
    if (n_groups < 2 or n_groups > max_groups) return error.Corrupt;
    const n_selectors = try r.get(15);
    if (n_selectors < 1) return error.Corrupt;
    var selectors: [max_selectors]u8 = undefined;
    var order: [max_groups]u8 = .{ 0, 1, 2, 3, 4, 5 };
    for (0..n_selectors) |i| {
        var j: u32 = 0;
        while (try r.bit() == 1) {
            j += 1;
            if (j >= n_groups) return error.Corrupt;
        }
        if (i >= max_selectors) continue;
        const v = order[j];
        var k = j;
        while (k > 0) : (k -= 1) order[k] = order[k - 1];
        order[0] = v;
        selectors[i] = v;
    }
    const used_selectors = @min(n_selectors, max_selectors);

    // The code lengths, each stored as a difference from the one before.
    var tables: [max_groups]Table = undefined;
    for (0..n_groups) |g| {
        var lengths: [max_alpha]u8 = undefined;
        var cur: i32 = @intCast(try r.get(5));
        for (0..alpha) |s| {
            while (true) {
                if (cur < 1 or cur > max_code_len) return error.Corrupt;
                if (try r.bit() == 0) break;
                cur += if (try r.bit() == 0) 1 else -1;
            }
            lengths[s] = @intCast(cur);
        }
        tables[g] = Table.init(lengths[0..alpha]);
    }

    // Symbols: zero runs (RUNA, RUNB in bijective base 2), move-to-front
    // positions, end of block.
    const limit = level * 100_000;
    var mtf: [256]u8 = undefined;
    for (0..in_use) |i| mtf[i] = @intCast(i);
    var counts: [256]u32 = @splat(0);
    var n: usize = 0;
    var group: usize = 0;
    var left: usize = 0;
    var table: *const Table = undefined;
    var run: u32 = 0;
    var run_weight: u32 = 1;
    while (true) {
        if (left == 0) {
            if (group >= used_selectors) return error.Corrupt;
            table = &tables[selectors[group]];
            group += 1;
            left = group_size;
        }
        left -= 1;
        const sym = try table.decode(r);
        if (sym <= 1) {
            // RUNA adds 1 x weight, RUNB 2 x weight.
            if (run_weight > limit) return error.Corrupt;
            run += run_weight << @intCast(sym);
            run_weight <<= 1;
            continue;
        }
        if (run > 0) {
            const b = seq_to_unseq[mtf[0]];
            if (n + run > limit) return error.Corrupt;
            counts[b] += run;
            @memset(tt[n .. n + run], b);
            n += run;
            run = 0;
            run_weight = 1;
        }
        if (sym == eob) break;
        if (n >= limit) return error.Corrupt;
        const pos = sym - 1;
        if (pos >= in_use) return error.Corrupt;
        const idx = mtf[pos];
        var k: usize = pos;
        while (k > 0) : (k -= 1) mtf[k] = mtf[k - 1];
        mtf[0] = idx;
        const b = seq_to_unseq[idx];
        counts[b] += 1;
        tt[n] = b;
        n += 1;
    }
    if (orig_ptr >= n) return error.Corrupt;

    // Undo the Burrows-Wheeler transform: link every position to its successor.
    var starts: [256]u32 = undefined;
    var sum: u32 = 0;
    for (0..256) |i| {
        starts[i] = sum;
        sum += counts[i];
    }
    for (0..n) |i| {
        const b = tt[i] & 0xff;
        tt[starts[b]] |= @as(u32, @intCast(i)) << 8;
        starts[b] += 1;
    }

    // Walk the links, undoing the run-length coding of the original bytes.
    var crc: u32 = 0xffff_ffff;
    var pos = tt[orig_ptr] >> 8;
    var last: i32 = -1;
    var same: u32 = 0;
    for (0..n) |_| {
        const entry = tt[pos];
        const ch: u8 = @intCast(entry & 0xff);
        pos = entry >> 8;
        if (same == 4) {
            // `ch` counts further copies of the byte before.
            if (out.items.len + ch > max_out) return error.TooLarge;
            const b: u8 = @intCast(last);
            for (0..ch) |_| {
                try out.append(gpa, b);
                crc = crcUpdate(crc, b);
            }
            same = 0;
            last = -1;
            continue;
        }
        if (ch == last) same += 1 else {
            last = ch;
            same = 1;
        }
        if (out.items.len >= max_out) return error.TooLarge;
        try out.append(gpa, ch);
        crc = crcUpdate(crc, ch);
    }
    crc = ~crc;
    if (crc != block_crc) return error.BadCrc;
    combined.* = ((combined.* << 1) | (combined.* >> 31)) ^ crc;
    return true;
}

/// Reads all of `input`, one or more bzip2 streams, and returns the bytes they
/// hold. Fails with `error.TooLarge` once the output passes `max_out` bytes.
pub fn decompress(gpa: Allocator, input: *Io.Reader, max_out: usize) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var streams: usize = 0;
    while (true) {
        var r: BitReader = .{ .input = input };
        // After the first stream, the end of the input ends the loop.
        const first = input.takeByte() catch |err| switch (err) {
            error.EndOfStream => if (streams > 0) break else return error.Corrupt,
            error.ReadFailed => return error.ReadFailed,
        };
        const magic_rest = input.takeArray(2) catch return error.Corrupt;
        if (first != 'B' or magic_rest[0] != 'Z' or magic_rest[1] != 'h') {
            // Bytes after the last stream: ignored, as bzip2 does.
            if (streams > 0) break;
            return error.Corrupt;
        }
        const digit = input.takeByte() catch return error.Corrupt;
        if (digit < '1' or digit > '9') return error.Corrupt;
        const level: u32 = digit - '0';
        const tt = try gpa.alloc(u32, level * 100_000);
        defer gpa.free(tt);
        var combined: u32 = 0;
        while (try block(gpa, &r, level, tt, &out, max_out, &combined)) {}
        r.align_();
        streams += 1;
    }
    return out.toOwnedSlice(gpa);
}

// ------------------------------------------------------------------- tests
// The fixtures were made with the bzip2 program.

const hello_bz2 = [_]u8{
    0x42, 0x5a, 0x68, 0x39, 0x31, 0x41, 0x59, 0x26, 0x53, 0x59, 0xc1, 0xc0, 0x80, 0xe2, 0x00, 0x00,
    0x01, 0x41, 0x00, 0x00, 0x10, 0x02, 0x44, 0xa0, 0x00, 0x30, 0xcd, 0x00, 0xc3, 0x46, 0x29, 0x97,
    0x17, 0x72, 0x45, 0x38, 0x50, 0x90, 0xc1, 0xc0, 0x80, 0xe2,
};

/// "a" x 300, "b", "cccc", "ddddd", "x" x 1000, newline: runs of every length class.
const runs_bz2 = [_]u8{
    0x42, 0x5a, 0x68, 0x39, 0x31, 0x41, 0x59, 0x26, 0x53, 0x59, 0xc0, 0x05, 0x2d, 0xfd, 0x00, 0x00,
    0x04, 0x51, 0x81, 0xe0, 0x10, 0x00, 0x20, 0x3c, 0x00, 0x00, 0x40, 0x00, 0x80, 0x00, 0x08, 0x20,
    0x00, 0x22, 0x3d, 0x50, 0x36, 0x24, 0x20, 0x1a, 0x69, 0xa2, 0xd4, 0x55, 0x58, 0xb6, 0x3b, 0x22,
    0x1a, 0x26, 0x14, 0x3d, 0x1f, 0x17, 0x72, 0x45, 0x38, 0x50, 0x90, 0xc0, 0x05, 0x2d, 0xfd,
};

/// "The quick brown fox jumps over the lazy dog. " x 40, bzip2 -1.
const fox_bz2 = [_]u8{
    0x42, 0x5a, 0x68, 0x31, 0x31, 0x41, 0x59, 0x26, 0x53, 0x59, 0xf8, 0x92, 0xd5, 0x55, 0x00, 0x00,
    0xdb, 0x93, 0x80, 0x40, 0x01, 0x04, 0x00, 0x3f, 0xff, 0xff, 0xf0, 0x30, 0x00, 0xd8, 0x05, 0x00,
    0x03, 0x40, 0x00, 0x05, 0x00, 0x03, 0x40, 0x00, 0x01, 0x4a, 0x94, 0xd4, 0xd3, 0x46, 0x8c, 0x26,
    0x86, 0xd4, 0xdb, 0x52, 0x60, 0x4e, 0x42, 0x64, 0x4f, 0xa1, 0x32, 0x27, 0xc0, 0x9a, 0x89, 0x81,
    0x35, 0x13, 0xa0, 0x9e, 0xe2, 0x7d, 0x89, 0x81, 0x3b, 0x09, 0x81, 0x3b, 0x04, 0xd8, 0x4d, 0xc2,
    0x77, 0x13, 0xc0, 0x9d, 0x44, 0xd8, 0x4f, 0x41, 0x3f, 0x04, 0xc0, 0x9b, 0x84, 0xc8, 0x9d, 0xc4,
    0xd0, 0x4e, 0x42, 0x6a, 0x27, 0x81, 0x34, 0x13, 0xa8, 0x9f, 0xc2, 0x6c, 0x26, 0x82, 0x64, 0x4c,
    0x89, 0xd0, 0x55, 0xe4, 0x4f, 0x22, 0x7f, 0x8b, 0xb9, 0x22, 0x9c, 0x28, 0x48, 0x7c, 0x49, 0x6a,
    0xaa, 0x80,
};

fn expectDecodes(want: []const u8, packed_bytes: []const u8) !void {
    var r: Io.Reader = .fixed(packed_bytes);
    const got = try decompress(std.testing.allocator, &r, 1 << 20);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(want, got);
}

test "streams made by bzip2" {
    try expectDecodes("hello\n", &hello_bz2);
    var want: std.ArrayList(u8) = .empty;
    defer want.deinit(std.testing.allocator);
    try want.appendNTimes(std.testing.allocator, 'a', 300);
    try want.append(std.testing.allocator, 'b');
    try want.appendSlice(std.testing.allocator, "ccccddddd");
    try want.appendNTimes(std.testing.allocator, 'x', 1000);
    try want.append(std.testing.allocator, '\n');
    try expectDecodes(want.items, &runs_bz2);
    var fox: std.ArrayList(u8) = .empty;
    defer fox.deinit(std.testing.allocator);
    for (0..40) |_| try fox.appendSlice(std.testing.allocator, "The quick brown fox jumps over the lazy dog. ");
    try expectDecodes(fox.items, &fox_bz2);
}

test "concatenated streams, and bytes after the last one" {
    try expectDecodes("hello\nhello\n", &(hello_bz2 ++ hello_bz2));
    try expectDecodes("hello\n", &(hello_bz2 ++ [_]u8{ 0, 0, 0 }));
}

test "damage is noticed" {
    var bad_crc = hello_bz2;
    bad_crc[12] ^= 1; // inside the block CRC
    var r: Io.Reader = .fixed(&bad_crc);
    try std.testing.expectError(error.BadCrc, decompress(std.testing.allocator, &r, 1 << 20));

    var damaged = fox_bz2;
    damaged[damaged.len / 2] ^= 0x10;
    var r1: Io.Reader = .fixed(&damaged);
    if (decompress(std.testing.allocator, &r1, 1 << 20)) |bytes| {
        std.testing.allocator.free(bytes);
        return error.TestUnexpectedResult;
    } else |_| {}

    var r2: Io.Reader = .fixed("not bzip2 at all");
    try std.testing.expectError(error.Corrupt, decompress(std.testing.allocator, &r2, 1 << 20));
    var r3: Io.Reader = .fixed(hello_bz2[0..20]);
    try std.testing.expectError(error.Corrupt, decompress(std.testing.allocator, &r3, 1 << 20));
    var r4: Io.Reader = .fixed("");
    try std.testing.expectError(error.Corrupt, decompress(std.testing.allocator, &r4, 1 << 20));
}

test "the output limit is enforced" {
    var r: Io.Reader = .fixed(&hello_bz2);
    try std.testing.expectError(error.TooLarge, decompress(std.testing.allocator, &r, 3));
    var r2: Io.Reader = .fixed(&runs_bz2);
    try std.testing.expectError(error.TooLarge, decompress(std.testing.allocator, &r2, 200));
}

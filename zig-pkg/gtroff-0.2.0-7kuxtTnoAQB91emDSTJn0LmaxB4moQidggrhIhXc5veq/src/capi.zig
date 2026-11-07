//! Optional C interface (see include/gtroff.h). EXPERIMENTAL: no stability promise.
//! Adapts the native API to C types only; the native API does not depend on it.

const std = @import("std");
const gtroff = @import("gtroff");

const gpa = std.heap.smp_allocator;

const ok = 0;
const err_invalid_argument = 1;
const err_out_of_memory = 2;

export fn gtroff_version() [*:0]const u8 {
    return "0.2.0";
}

fn input(src: ?[*]const u8, len: usize) ?[]const u8 {
    if (src == null and len != 0) return null;
    return if (src) |p| p[0..len] else "";
}

const Format = enum { man, mdoc };

fn toText(format: Format, src: ?[*]const u8, len: usize, width: usize, color: c_int, out: ?*?[*]u8, out_len: ?*usize) c_int {
    const o = out orelse return err_invalid_argument;
    const l = out_len orelse return err_invalid_argument;
    o.* = null;
    l.* = 0;
    const bytes = input(src, len) orelse return err_invalid_argument;
    var doc = (switch (format) {
        .man => gtroff.parseMan(gpa, bytes),
        .mdoc => gtroff.parseMdoc(gpa, bytes),
    }) catch return err_out_of_memory;
    defer doc.deinit();
    const s = doc.toTextAlloc(gpa, .{ .width = width, .color = color != 0 }) catch return err_out_of_memory;
    o.* = s.ptr;
    l.* = s.len;
    return ok;
}

fn toHtml(format: Format, src: ?[*]const u8, len: usize, out: ?*?[*]u8, out_len: ?*usize) c_int {
    const o = out orelse return err_invalid_argument;
    const l = out_len orelse return err_invalid_argument;
    o.* = null;
    l.* = 0;
    const bytes = input(src, len) orelse return err_invalid_argument;
    var doc = (switch (format) {
        .man => gtroff.parseMan(gpa, bytes),
        .mdoc => gtroff.parseMdoc(gpa, bytes),
    }) catch return err_out_of_memory;
    defer doc.deinit();
    const s = doc.toHtmlAlloc(gpa) catch return err_out_of_memory;
    o.* = s.ptr;
    l.* = s.len;
    return ok;
}

export fn gtroff_man_to_text(src: ?[*]const u8, len: usize, width: usize, color: c_int, out: ?*?[*]u8, out_len: ?*usize) c_int {
    return toText(.man, src, len, width, color, out, out_len);
}

export fn gtroff_man_to_html(src: ?[*]const u8, len: usize, out: ?*?[*]u8, out_len: ?*usize) c_int {
    return toHtml(.man, src, len, out, out_len);
}

export fn gtroff_mdoc_to_text(src: ?[*]const u8, len: usize, width: usize, color: c_int, out: ?*?[*]u8, out_len: ?*usize) c_int {
    return toText(.mdoc, src, len, width, color, out, out_len);
}

export fn gtroff_mdoc_to_html(src: ?[*]const u8, len: usize, out: ?*?[*]u8, out_len: ?*usize) c_int {
    return toHtml(.mdoc, src, len, out, out_len);
}

export fn gtroff_free_string(ptr: ?[*]u8, len: usize) void {
    const p = ptr orelse return;
    gpa.free(p[0..len]);
}

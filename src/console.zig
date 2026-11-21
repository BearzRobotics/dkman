//! The terminal, for the parts that differ between systems: its size, making
//! it understand ANSI styles and UTF-8, and reading keys one at a time (the
//! browser, `-b`). POSIX systems use termios and poll; Windows uses the
//! console API with virtual terminal sequences, so the rest of dkman writes and
//! reads the same bytes everywhere.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

pub const Size = struct { rows: usize, cols: usize };

const is_windows = builtin.os.tag == .windows;

// ------------------------------------------------------------------ windows

const win = if (is_windows) struct {
    const HANDLE = std.os.windows.HANDLE;
    const std_input: u32 = @bitCast(@as(i32, -10));
    const std_output: u32 = @bitCast(@as(i32, -11));
    const utf8: u32 = 65001;

    const enable_processed_input: u32 = 0x0001;
    const enable_line_input: u32 = 0x0002;
    const enable_echo_input: u32 = 0x0004;
    const enable_virtual_terminal_input: u32 = 0x0200;
    const enable_processed_output: u32 = 0x0001;
    const enable_virtual_terminal_processing: u32 = 0x0004;

    const Coord = extern struct { x: i16, y: i16 };
    const SmallRect = extern struct { left: i16, top: i16, right: i16, bottom: i16 };
    const ScreenBufferInfo = extern struct {
        size: Coord,
        cursor: Coord,
        attributes: u16,
        window: SmallRect,
        maximum_window_size: Coord,
    };

    extern "kernel32" fn GetStdHandle(n: u32) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn GetConsoleMode(h: HANDLE, mode: *u32) callconv(.winapi) i32;
    extern "kernel32" fn SetConsoleMode(h: HANDLE, mode: u32) callconv(.winapi) i32;
    extern "kernel32" fn SetConsoleOutputCP(cp: u32) callconv(.winapi) i32;
    extern "kernel32" fn SetConsoleCP(cp: u32) callconv(.winapi) i32;
    extern "kernel32" fn GetConsoleScreenBufferInfo(h: HANDLE, info: *ScreenBufferInfo) callconv(.winapi) i32;
    extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: u32) callconv(.winapi) u32;
    extern "kernel32" fn ReadFile(h: HANDLE, buf: [*]u8, len: u32, read: *u32, overlapped: ?*anyopaque) callconv(.winapi) i32;

    fn handle(which: u32) ?HANDLE {
        const h = GetStdHandle(which) orelse return null;
        if (h == std.os.windows.INVALID_HANDLE_VALUE) return null;
        return h;
    }
} else struct {};

/// Makes standard output ready for dkman's text: ANSI styles processed and
/// UTF-8 accepted. Returns false when the console cannot do styles (an old
/// console host), so the caller leaves color off. Does nothing, and returns
/// true, on other systems.
pub fn prepareOutput() bool {
    if (!is_windows) return true;
    const out = win.handle(win.std_output) orelse return false;
    var mode: u32 = 0;
    // Not a console (a file or pipe): there is nothing to set up.
    if (win.GetConsoleMode(out, &mode) == 0) return true;
    _ = win.SetConsoleOutputCP(win.utf8);
    return win.SetConsoleMode(out, mode | win.enable_processed_output | win.enable_virtual_terminal_processing) != 0;
}

/// True when standard output is a console whose code page `prepareOutput` set
/// to UTF-8, so non-ASCII text is shown correctly. Always false off Windows.
pub fn outputIsUtf8Console() bool {
    if (!is_windows) return false;
    const out = win.handle(win.std_output) orelse return false;
    var mode: u32 = 0;
    return win.GetConsoleMode(out, &mode) != 0;
}

// --------------------------------------------------------------------- size

pub fn terminalSize() Size {
    if (is_windows) {
        const out = win.handle(win.std_output) orelse return .{ .rows = 24, .cols = 80 };
        var info: win.ScreenBufferInfo = undefined;
        if (win.GetConsoleScreenBufferInfo(out, &info) != 0) {
            // The visible window, not the (often much taller) scroll-back buffer.
            const cols = @as(i32, info.window.right) - info.window.left + 1;
            const rows = @as(i32, info.window.bottom) - info.window.top + 1;
            if (cols > 0 and rows > 0) return .{ .rows = @intCast(rows), .cols = @intCast(cols) };
        }
        return .{ .rows = 24, .cols = 80 };
    }
    var ws: posix.winsize = undefined;
    const ok = switch (builtin.os.tag) {
        .linux => std.os.linux.errno(std.os.linux.ioctl(1, std.os.linux.T.IOCGWINSZ, @intFromPtr(&ws))) == .SUCCESS,
        // The BSDs and macOS always have libc, whose ioctl takes the request.
        .macos, .freebsd, .netbsd, .openbsd, .dragonfly => std.c.ioctl(1, std.c.T.IOCGWINSZ, @intFromPtr(&ws)) == 0,
        else => false,
    };
    if (ok and ws.col > 0 and ws.row > 0) return .{ .rows = ws.row, .cols = ws.col };
    return .{ .rows = 24, .cols = 80 };
}

// -------------------------------------------------------------------- input

/// True when a key can be read within `timeout_ms` (0: right now).
pub fn inputPending(timeout_ms: i32) bool {
    if (is_windows) {
        const in = win.handle(win.std_input) orelse return false;
        // 0 is WAIT_OBJECT_0: the handle is signalled, input is waiting.
        return win.WaitForSingleObject(in, @intCast(timeout_ms)) == 0;
    }
    var fds = [_]posix.pollfd{.{ .fd = 0, .events = posix.POLL.IN }};
    const n = posix.poll(&fds, timeout_ms) catch return false;
    return n > 0;
}

/// Reads what the user typed, as the bytes a terminal sends (escape sequences
/// for the arrow keys). Zero bytes means the input ended.
pub fn readInput(buf: []u8) !usize {
    if (is_windows) {
        const in = win.handle(win.std_input) orelse return error.NotATerminal;
        var n: u32 = 0;
        if (win.ReadFile(in, buf.ptr, @intCast(buf.len), &n, null) == 0) return error.ReadFailed;
        return n;
    }
    return posix.read(0, buf);
}

/// The terminal taking keys one at a time, without echo or line editing.
pub const RawMode = struct {
    saved: if (is_windows) struct { input: u32, output: u32 } else posix.termios,

    pub fn enter() !RawMode {
        if (is_windows) {
            const in = win.handle(win.std_input) orelse return error.NotATerminal;
            const out = win.handle(win.std_output) orelse return error.NotATerminal;
            var in_mode: u32 = 0;
            var out_mode: u32 = 0;
            if (win.GetConsoleMode(in, &in_mode) == 0 or win.GetConsoleMode(out, &out_mode) == 0) return error.NotATerminal;
            // Keys arrive as the same escape sequences a POSIX terminal sends.
            const raw = (in_mode & ~(win.enable_line_input | win.enable_echo_input | win.enable_processed_input)) | win.enable_virtual_terminal_input;
            if (win.SetConsoleMode(in, raw) == 0) return error.NotATerminal;
            _ = win.SetConsoleCP(win.utf8);
            _ = win.SetConsoleMode(out, out_mode | win.enable_processed_output | win.enable_virtual_terminal_processing);
            return .{ .saved = .{ .input = in_mode, .output = out_mode } };
        }
        const saved = posix.tcgetattr(0) catch return error.NotATerminal;
        var raw = saved;
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;
        raw.iflag.BRKINT = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.cc[@backingInt(std.os.linux.V.MIN)] = 1;
        raw.cc[@backingInt(std.os.linux.V.TIME)] = 0;
        try posix.tcsetattr(0, .FLUSH, raw);
        return .{ .saved = saved };
    }

    pub fn leave(r: RawMode) void {
        if (is_windows) {
            if (win.handle(win.std_input)) |in| _ = win.SetConsoleMode(in, r.saved.input);
            if (win.handle(win.std_output)) |out| _ = win.SetConsoleMode(out, r.saved.output);
            return;
        }
        posix.tcsetattr(0, .FLUSH, r.saved) catch {};
    }
};

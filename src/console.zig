// SPDX-License-Identifier: GPL-2.0-or-later
//! The terminal, for the parts that differ between systems: its size, making
//! it understand ANSI styles and UTF-8, and reading keys one at a time (the
//! browser, `-b`). POSIX systems use termios and poll; Windows uses the
//! console API with virtual terminal sequences, so the rest of dkman writes and
//! reads the same bytes everywhere.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Io = std.Io;

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
    extern "kernel32" fn PeekConsoleInputW(h: HANDLE, buf: *InputRecord, len: u32, read: *u32) callconv(.winapi) i32;
    extern "kernel32" fn ReadConsoleInputW(h: HANDLE, buf: *InputRecord, len: u32, read: *u32) callconv(.winapi) i32;
    extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

    /// `INPUT_RECORD` with the `KEY_EVENT_RECORD` member of its union; the
    /// other members (mouse, window size, menu, focus) fit in its 16 bytes.
    const InputRecord = extern struct {
        event_type: u16,
        event: extern union {
            key: extern struct {
                key_down: i32,
                repeat_count: u16,
                virtual_key_code: u16,
                virtual_scan_code: u16,
                char: u16,
                control_key_state: u32,
            },
            other: [16]u8,
        },
    };
    const key_event: u16 = 0x0001;
    extern "kernel32" fn ReadFile(h: HANDLE, buf: [*]u8, len: u32, read: *u32, overlapped: ?*anyopaque) callconv(.winapi) i32;

    extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, security: ?*anyopaque, disposition: u32, flags: u32, template: ?HANDLE) callconv(.winapi) HANDLE;
    extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) i32;

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

// ---------------------------------------------------------------- streams

/// Standard input, output and error. Use these, not `Io.File.stdin()` and
/// friends: Windows can hand a program asynchronous pipes (its SSH server
/// does), and std takes the three to be synchronous. A read or write that then
/// has to wait ends in `unreachable`.
pub fn stdin() Io.File {
    return asOpened(Io.File.stdin());
}

pub fn stdout() Io.File {
    return asOpened(Io.File.stdout());
}

pub fn stderr() Io.File {
    return asOpened(Io.File.stderr());
}

/// `file` with its `nonblocking` flag matching how the handle was opened.
fn asOpened(file: Io.File) Io.File {
    if (!is_windows) return file;
    const w = std.os.windows;
    var iosb: w.IO_STATUS_BLOCK = undefined;
    var mode: w.FILE.MODE = undefined;
    // This fails for a console handle, which is synchronous.
    const status = w.ntdll.NtQueryInformationFile(file.handle, &iosb, &mode, @sizeOf(w.FILE.MODE), .Mode);
    var result = file;
    if (status == .SUCCESS and mode.IO == .ASYNCHRONOUS) result.flags.nonblocking = true;
    return result;
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
    return pendingOn(standardInput() orelse return false, timeout_ms);
}

/// What keys are read from: a handle on Windows, a descriptor elsewhere.
const Input = Io.File.Handle;

fn standardInput() ?Input {
    if (is_windows) return win.handle(win.std_input);
    return 0;
}

fn pendingOn(in: Input, timeout_ms: i32) bool {
    if (is_windows) {
        // The console's input handle is signalled for any event in its queue,
        // also those ReadFile never returns: a key being released (the Enter
        // that started dkman is the first thing there), a key with no
        // character (Shift), focus, menu and window-size events. Taking one
        // of those for a key made the browser skip drawing and wait in
        // ReadFile until a real key came. They are dropped here.
        const deadline = win.GetTickCount64() + @as(u64, @intCast(@max(timeout_ms, 0)));
        while (true) {
            var rec: win.InputRecord = undefined;
            var n: u32 = 0;
            // Not a console (redirected input): any data is input.
            if (win.PeekConsoleInputW(in, &rec, 1, &n) == 0) return win.WaitForSingleObject(in, @intCast(@max(timeout_ms, 0))) == 0;
            if (n > 0) {
                if (rec.event_type == win.key_event and rec.event.key.key_down != 0 and rec.event.key.char != 0) return true;
                if (win.ReadConsoleInputW(in, &rec, 1, &n) == 0) return false;
                continue;
            }
            const now = win.GetTickCount64();
            if (now >= deadline) return false;
            // 0 is WAIT_OBJECT_0: something arrived; look at it.
            if (win.WaitForSingleObject(in, @intCast(deadline - now)) != 0) return false;
        }
    }
    var fds = [_]posix.pollfd{.{ .fd = in, .events = posix.POLL.IN }};
    const n = posix.poll(&fds, timeout_ms) catch return false;
    return n > 0;
}

/// Reads what the user typed, as the bytes a terminal sends (escape sequences
/// for the arrow keys). Zero bytes means the input ended.
pub fn readInput(buf: []u8) !usize {
    return readOn(standardInput() orelse return error.NotATerminal, buf);
}

fn readOn(in: Input, buf: []u8) !usize {
    if (is_windows) {
        var n: u32 = 0;
        if (win.ReadFile(in, buf.ptr, @intCast(buf.len), &n, null) == 0) return error.ReadFailed;
        return n;
    }
    return posix.read(in, buf);
}

/// The terminal taking keys one at a time, without echo or line editing.
pub const RawMode = struct {
    in: Input,
    saved: if (is_windows) struct { input: u32, output: u32 } else posix.termios,

    pub fn enter() !RawMode {
        return enterOn(standardInput() orelse return error.NotATerminal);
    }

    fn enterOn(in: Input) !RawMode {
        if (is_windows) {
            const out = win.handle(win.std_output) orelse return error.NotATerminal;
            var in_mode: u32 = 0;
            var out_mode: u32 = 0;
            if (win.GetConsoleMode(in, &in_mode) == 0 or win.GetConsoleMode(out, &out_mode) == 0) return error.NotATerminal;
            // Keys arrive as the same escape sequences a POSIX terminal sends.
            const raw = (in_mode & ~(win.enable_line_input | win.enable_echo_input | win.enable_processed_input)) | win.enable_virtual_terminal_input;
            if (win.SetConsoleMode(in, raw) == 0) return error.NotATerminal;
            _ = win.SetConsoleCP(win.utf8);
            _ = win.SetConsoleMode(out, out_mode | win.enable_processed_output | win.enable_virtual_terminal_processing);
            return .{ .in = in, .saved = .{ .input = in_mode, .output = out_mode } };
        }
        const saved = posix.tcgetattr(in) catch return error.NotATerminal;
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
        try posix.tcsetattr(in, .FLUSH, raw);
        return .{ .in = in, .saved = saved };
    }

    pub fn leave(r: RawMode) void {
        if (is_windows) {
            _ = win.SetConsoleMode(r.in, r.saved.input);
            if (win.handle(win.std_output)) |out| _ = win.SetConsoleMode(out, r.saved.output);
            return;
        }
        posix.tcsetattr(r.in, .FLUSH, r.saved) catch {};
    }
};

/// The keys of the terminal itself, in raw mode. It is opened by name, so it
/// works while standard input is the page (`zcat x.1.gz | dkman -l -`).
pub const Keyboard = struct {
    raw: RawMode,

    /// Null when there is no terminal to read keys from.
    pub fn open(io: Io) ?Keyboard {
        const in = openTerminal(io) orelse return null;
        const raw = RawMode.enterOn(in) catch {
            closeInput(io, in);
            return null;
        };
        return .{ .raw = raw };
    }

    /// Restores the terminal.
    pub fn close(k: Keyboard, io: Io) void {
        k.raw.leave();
        closeInput(io, k.raw.in);
    }

    /// As `inputPending`.
    pub fn pending(k: Keyboard, timeout_ms: i32) bool {
        return pendingOn(k.raw.in, timeout_ms);
    }

    /// As `readInput`.
    pub fn read(k: Keyboard, buf: []u8) !usize {
        return readOn(k.raw.in, buf);
    }

    fn openTerminal(io: Io) ?Input {
        if (is_windows) {
            const name = std.unicode.utf8ToUtf16LeStringLiteral("CONIN$");
            // Read and write access, shared both ways, an existing device.
            const h = win.CreateFileW(name, 0xc0000000, 3, null, 3, 0, null);
            return if (h == std.os.windows.INVALID_HANDLE_VALUE) null else h;
        }
        const file = Io.Dir.cwd().openFile(io, "/dev/tty", .{ .mode = .read_write }) catch return null;
        return file.handle;
    }

    fn closeInput(io: Io, in: Input) void {
        if (is_windows) {
            _ = win.CloseHandle(in);
            return;
        }
        const file: Io.File = .{ .handle = in, .flags = .{ .nonblocking = false } };
        file.close(io);
    }
};

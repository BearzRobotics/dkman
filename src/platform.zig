//! Where things live on this system: the separator of path lists, the manual
//! directories of tools commonly installed on Windows (Git for Windows, MSYS2,
//! Cygwin, Scoop, rustup), dkman's own data directory and the documentation
//! sets `--fetch-docs` stores in it.
//!
//! Functions take the environment and `std.Io` as arguments and look at
//! nothing else, so the Windows rules run in tests on any system.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Env = std.process.Environ.Map;

const is_windows = builtin.os.tag == .windows;

/// Separates the entries of `MANPATH`, `PATH` and `-M` (`;` on Windows, where
/// a colon belongs to a drive letter).
pub const list_separator: u8 = if (is_windows) ';' else ':';

pub fn nonEmpty(s: ?[]const u8) ?[]const u8 {
    const v = s orelse return null;
    return if (v.len > 0) v else null;
}

fn dirExists(io: Io, path: []const u8) bool {
    var d = Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    d.close(io);
    return true;
}

/// True for a page argument that names a file rather than a page: it has a
/// directory separator (either kind on Windows) or a drive letter.
pub fn looksLikePath(arg: []const u8) bool {
    if (std.mem.findScalar(u8, arg, '/') != null) return true;
    if (!is_windows) return false;
    return std.mem.findScalar(u8, arg, '\\') != null or (arg.len >= 2 and arg[1] == ':' and std.ascii.isAlphabetic(arg[0]));
}

// ------------------------------------------------------- windows man trees

/// Where a manual tree may sit under an install root.
const man_subdirs = [_][]const u8{ "man", "share/man", "usr/share/man", "mingw64/share/man", "ucrt64/share/man", "clang64/share/man" };

fn addIfDir(arena: Allocator, io: Io, out: *std.ArrayList([]const u8), parts: []const []const u8) Allocator.Error!void {
    const p = try std.fs.path.join(arena, parts);
    if (!dirExists(io, p)) return;
    for (out.items) |have| if (std.mem.eql(u8, have, p)) return;
    try out.append(arena, p);
}

fn addUnderRoot(arena: Allocator, io: Io, out: *std.ArrayList([]const u8), root: []const u8) Allocator.Error!void {
    for (man_subdirs) |sub| try addIfDir(arena, io, out, &.{ root, sub });
}

/// For each subdirectory of `apps` (`apps/git`, `toolchains/stable-...`), its
/// manual directories; Scoop keeps the live version under `current`.
fn addAppDirs(arena: Allocator, io: Io, out: *std.ArrayList([]const u8), apps: []const u8, has_current: bool) Allocator.Error!void {
    var dir = Io.Dir.cwd().openDir(io, apps, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .directory and e.kind != .sym_link) continue;
        const app = try std.fs.path.join(arena, &.{ apps, e.name });
        try addUnderRoot(arena, io, out, if (has_current) try std.fs.path.join(arena, &.{ app, "current" }) else app);
    }
}

/// Manual directories of software that ships man pages on Windows, only those
/// that exist: Git for Windows, MSYS2, Cygwin, Scoop apps and rustup toolchains.
/// (A tool's own `PATH` entry also finds its pages, see `paths.deriveManpath`.)
pub fn windowsManDirs(arena: Allocator, io: Io, env: *const Env) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const drive = nonEmpty(env.get("SystemDrive")) orelse "C:";
    const drive_root = try std.fmt.allocPrint(arena, "{s}\\", .{drive});

    // Git for Windows keeps an MSYS tree (`usr`) and a `mingw64` tree.
    for ([_][]const u8{ "ProgramFiles", "ProgramW6432", "ProgramFiles(x86)" }) |var_name| {
        const base = nonEmpty(env.get(var_name)) orelse continue;
        try addUnderRoot(arena, io, &out, try std.fs.path.join(arena, &.{ base, "Git" }));
    }
    if (nonEmpty(env.get("LOCALAPPDATA"))) |base| {
        try addUnderRoot(arena, io, &out, try std.fs.path.join(arena, &.{ base, "Programs", "Git" }));
    }
    for ([_][]const u8{ "msys64", "msys32", "cygwin64", "cygwin" }) |name| {
        try addUnderRoot(arena, io, &out, try std.fs.path.join(arena, &.{ drive_root, name }));
    }
    if (nonEmpty(env.get("USERPROFILE"))) |home| {
        try addAppDirs(arena, io, &out, try std.fs.path.join(arena, &.{ home, "scoop", "apps" }), true);
        try addAppDirs(arena, io, &out, try std.fs.path.join(arena, &.{ home, ".rustup", "toolchains" }), false);
    }
    if (nonEmpty(env.get("SCOOP"))) |scoop| try addAppDirs(arena, io, &out, try std.fs.path.join(arena, &.{ scoop, "apps" }), true);
    return out.items;
}

// ---------------------------------------------------------- data, cache, config

/// dkman's per-user data directory: `%LOCALAPPDATA%\dkman` on Windows,
/// `$XDG_DATA_HOME/dkman` or `~/.local/share/dkman` elsewhere.
pub fn dataDir(arena: Allocator, env: *const Env) Allocator.Error!?[]const u8 {
    if (is_windows) {
        if (nonEmpty(env.get("LOCALAPPDATA"))) |d| return try std.fs.path.join(arena, &.{ d, "dkman" });
        if (nonEmpty(env.get("USERPROFILE"))) |h| return try std.fs.path.join(arena, &.{ h, "AppData", "Local", "dkman" });
        return null;
    }
    if (nonEmpty(env.get("XDG_DATA_HOME"))) |x| return try std.fs.path.join(arena, &.{ x, "dkman" });
    if (nonEmpty(env.get("HOME"))) |h| return try std.fs.path.join(arena, &.{ h, ".local", "share", "dkman" });
    return null;
}

/// Directories the page index may be kept in, best first: the system-wide one
/// (written by `mandb` run as an administrator, read by everyone), then the
/// user's cache.
pub fn cacheDirs(arena: Allocator, env: *const Env) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (is_windows) {
        if (nonEmpty(env.get("ProgramData"))) |d| try out.append(arena, try std.fs.path.join(arena, &.{ d, "dkman", "cache" }));
        if (nonEmpty(env.get("LOCALAPPDATA"))) |d| try out.append(arena, try std.fs.path.join(arena, &.{ d, "dkman", "cache" }));
        return out.items;
    }
    try out.append(arena, "/var/cache/dkman");
    if (nonEmpty(env.get("XDG_CACHE_HOME"))) |x| {
        try out.append(arena, try std.fs.path.join(arena, &.{ x, "dkman" }));
    } else if (nonEmpty(env.get("HOME"))) |h| {
        try out.append(arena, try std.fs.path.join(arena, &.{ h, ".cache", "dkman" }));
    }
    return out.items;
}

/// The configuration files to read, first found wins: man-db's on POSIX
/// systems, `%ProgramData%\dkman\manpath.config` on Windows.
pub fn configFiles(arena: Allocator, env: *const Env) Allocator.Error![]const []const u8 {
    if (is_windows) {
        const d = nonEmpty(env.get("ProgramData")) orelse return &.{};
        return &.{try std.fs.path.join(arena, &.{ d, "dkman", "manpath.config" })};
    }
    return &.{ "/etc/manpath.config", "/etc/man_db.conf" };
}

/// `path` made absolute when it exists (so that a cache keyed by it does not
/// change with the working directory), else as given.
pub fn absolute(arena: Allocator, io: Io, path: []const u8) Allocator.Error![]const u8 {
    return Io.Dir.cwd().realPathFileAlloc(io, path, arena) catch try arena.dupe(u8, path);
}

/// Where fetched documentation sets live: one directory per set, each a
/// manual directory (`manps`, `mancmd`, ...). `override` (from `--docs-dir` or
/// `DKMAN_DOCS`) is the user's documentation folder (a toolkit on a USB drive
/// for one): the sets go in its `dkman` subdirectory, and the rest of it holds
/// the user's own pages (see `paths.scanLoose`). A folder that already holds
/// sets itself (dkman 0.6.0's layout) keeps them there. Otherwise `<data>/docs`.
pub fn docsRoot(arena: Allocator, io: Io, env: *const Env, override: ?[]const u8) Allocator.Error!?[]const u8 {
    if (override) |o| {
        if (holdsSets(io, o)) return o;
        return try std.fs.path.join(arena, &.{ o, sets_subdir });
    }
    const data = (try dataDir(arena, env)) orelse return null;
    return try std.fs.path.join(arena, &.{ data, "docs" });
}

/// The subdirectory of a documentation folder that dkman's sets live in.
pub const sets_subdir = "dkman";

/// Does `dir` have an installed set directly inside it?
fn holdsSets(io: Io, dir_path: []const u8) bool {
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var it = dir.iterate();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    while (it.next(io) catch null) |e| {
        if (e.kind != .directory or e.name[0] == '.') continue;
        const manifest = std.fmt.bufPrint(&buf, "{s}{c}{s}", .{ e.name, std.fs.path.sep, @import("fetch.zig").manifest_name }) catch continue;
        _ = dir.statFile(io, manifest, .{}) catch continue;
        return true;
    }
    return false;
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// The fetched sets that exist, as manual directories, sorted by name.
pub fn docDirs(arena: Allocator, io: Io, env: *const Env, override: ?[]const u8) Allocator.Error![]const []const u8 {
    const root = (try docsRoot(arena, io, env, override)) orelse return &.{};
    var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);
    var out: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        // `.name.new` is a set being downloaded.
        if (e.kind != .directory or e.name[0] == '.') continue;
        // Only sets dkman installed: the directory may hold the user's own
        // documents beside them.
        const manifest = try std.fs.path.join(arena, &.{ e.name, @import("fetch.zig").manifest_name });
        _ = dir.statFile(io, manifest, .{}) catch continue;
        try out.append(arena, try std.fs.path.join(arena, &.{ root, e.name }));
    }
    std.mem.sort([]const u8, out.items, {}, lessThanStr);
    return out.items;
}

/// The pager used when none is configured, and the one tried when it cannot
/// be started.
pub const default_pager = "less";
pub const fallback_pager: ?[]const u8 = if (is_windows) "more.com" else null;

test "windowsManDirs finds Git, Scoop and rustup trees that exist" {
    const t = std.testing;
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "pf/Git/usr/share/man");
    try tmp.dir.createDirPath(io, "pf/Git/mingw64/share/man");
    try tmp.dir.createDirPath(io, "home/scoop/apps/curl/current/man");
    try tmp.dir.createDirPath(io, "home/scoop/apps/curl/1.0/man");
    try tmp.dir.createDirPath(io, "home/.rustup/toolchains/stable/share/man");
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    var env: Env = .init(a);
    try env.put("ProgramFiles", try std.fs.path.join(a, &.{ root, "pf" }));
    try env.put("USERPROFILE", try std.fs.path.join(a, &.{ root, "home" }));
    try env.put("SystemDrive", try std.fs.path.join(a, &.{ root, "nodrive" }));
    const dirs = try windowsManDirs(a, io, &env);
    // Git usr + mingw64, Scoop current (not the old version), rustup.
    try t.expectEqual(@as(usize, 4), dirs.len);
}

test "docDirs lists the fetched sets and skips downloads in progress" {
    const t = std.testing;
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "data/dkman/docs/powershell-7.6/manps");
    try tmp.dir.createDirPath(io, "data/dkman/docs/cmd/mancmd");
    try tmp.dir.createDirPath(io, "data/dkman/docs/.wsl.new/manwsl");
    try tmp.dir.writeFile(io, .{ .sub_path = "data/dkman/docs/powershell-7.6/dkman-set", .data = "id=powershell-7.6\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "data/dkman/docs/cmd/dkman-set", .data = "id=cmd\n" });
    // The user's own documents beside the sets are not a set.
    try tmp.dir.createDirPath(io, "data/dkman/docs/bash/manual");
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    var env: Env = .init(a);
    try env.put(if (is_windows) "LOCALAPPDATA" else "XDG_DATA_HOME", try std.fs.path.join(a, &.{ root, "data" }));
    const dirs = try docDirs(a, io, &env, null);
    try t.expectEqual(@as(usize, 2), dirs.len);
    try t.expect(std.mem.endsWith(u8, dirs[0], "cmd"));
    try t.expect(std.mem.endsWith(u8, dirs[1], "powershell-7.6"));

    // A directory given by the user is used as it is.
    const given = try std.fs.path.join(a, &.{ root, "data", "dkman", "docs" });
    const other = try docDirs(a, io, &env, given);
    try t.expectEqual(@as(usize, 2), other.len);
    try t.expectEqual(@as(usize, 0), (try docDirs(a, io, &env, try std.fs.path.join(a, &.{ root, "nowhere" }))).len);
}

test "looksLikePath" {
    try std.testing.expect(looksLikePath("man1/ls.1"));
    try std.testing.expect(!looksLikePath("ls"));
}

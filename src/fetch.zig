//! `dkman --fetch-docs`: downloads documentation repositories from GitHub and
//! keeps their Markdown pages as manual directories (see `docsets.zig`).
//!
//! The repository's archive (`codeload.github.com/OWNER/REPO/tar.gz/refs/heads/REF`)
//! is read as a stream: gunzipped and untarred as it arrives, nothing but the
//! chosen pages is written, and no external program (git, tar, curl) is used.
//! Each set is written to `.SET.new` and swapped in when complete, so a failed
//! download leaves the old copy in place.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;
const docsets = @import("docsets.zig");

/// Largest page kept; the biggest in these repositories is far below this.
const max_page_bytes: u64 = 8 * 1024 * 1024;

pub const manifest_name = "dkman-set";

/// What an installed set says about itself (the `dkman-set` file).
pub const Info = struct {
    id: []const u8,
    topic: []const u8,
    version: []const u8,
    title: []const u8,
    pages: usize,
};

pub fn parseManifest(text: []const u8) ?Info {
    var info: Info = .{ .id = "", .topic = "", .version = "", .title = "", .pages = 0 };
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const eq = std.mem.findScalar(u8, line, '=') orelse continue;
        const key = line[0..eq];
        const value = line[eq + 1 ..];
        if (std.mem.eql(u8, key, "id")) info.id = value;
        if (std.mem.eql(u8, key, "topic")) info.topic = value;
        if (std.mem.eql(u8, key, "version")) info.version = value;
        if (std.mem.eql(u8, key, "title")) info.title = value;
        if (std.mem.eql(u8, key, "pages")) info.pages = std.fmt.parseInt(usize, value, 10) catch 0;
    }
    return if (info.id.len > 0) info else null;
}

/// The installed sets below `root` (the manifests that can be read).
pub fn installed(arena: Allocator, io: Io, root: []const u8) Allocator.Error![]const Info {
    var out: std.ArrayList(Info) = .empty;
    var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return out.items;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .directory or e.name[0] == '.') continue;
        const path = try std.fs.path.join(arena, &.{ e.name, manifest_name });
        const text = dir.readFileAlloc(io, path, arena, .limited(64 * 1024)) catch continue;
        if (parseManifest(text)) |info| try out.append(arena, info);
    }
    return out.items;
}

/// One set being written.
const Staging = struct {
    set: *const docsets.Set,
    /// `.SET.new` below the docs root.
    dir: []const u8,
    pages: usize = 0,
};

pub const Error = error{ HttpStatus, BadArchive } || Allocator.Error;

pub const Result = struct {
    /// Pages written, over all the sets installed.
    pages: usize = 0,
    /// Sets that could not be installed (each reported on standard error).
    failed: usize = 0,
};

/// How often a repository's download is tried before its sets are given up:
/// a connection dropped halfway through a large archive is the usual failure.
const attempts = 3;

/// Installs `sets` (all of them from repositories downloaded once each) below
/// `root`, reporting on standard error. A repository that cannot be
/// downloaded does not stop the others; its sets are counted as failed and an
/// installed copy of them is kept.
pub fn install(gpa: Allocator, arena: Allocator, io: Io, env: *const std.process.Environ.Map, root: []const u8, sets: []const *const docsets.Set) Allocator.Error!Result {
    var result: Result = .{};
    Io.Dir.cwd().createDirPath(io, root) catch |err| {
        say(io, "dkman: cannot create {s}: {s}\n", .{ root, describe(err) });
        result.failed = sets.len;
        return result;
    };
    var done: std.StringHashMapUnmanaged(void) = .empty;
    for (sets) |first| {
        if (done.contains(first.repo)) continue;
        try done.put(arena, first.repo, {});
        // Every requested set of this repository.
        var group: std.ArrayList(Staging) = .empty;
        for (sets) |s| {
            if (!std.mem.eql(u8, s.repo, first.repo) or !std.mem.eql(u8, s.ref, first.ref)) continue;
            const dir = try std.fs.path.join(arena, &.{ root, try std.fmt.allocPrint(arena, ".{s}.new", .{s.id}) });
            try group.append(arena, .{ .set = s, .dir = dir });
        }
        say(io, "{s}: downloading (about {d} MB; only Markdown pages are kept)...\n", .{ first.repo, docsets.repoSize(first.repo) });
        var attempt: usize = 1;
        while (true) : (attempt += 1) {
            const outcome = installGroup(gpa, arena, io, env, root, first, group.items);
            if (outcome) |pages| {
                result.pages += pages;
                break;
            } else |err| {
                for (group.items) |g| Io.Dir.cwd().deleteTree(io, g.dir) catch {};
                if (err == error.OutOfMemory) return error.OutOfMemory;
                if (attempt < attempts and retryable(err)) {
                    say(io, "dkman: {s}: {s}; trying again ({d} of {d})...\n", .{ first.repo, describe(err), attempt + 1, attempts });
                    io.sleep(.fromSeconds(@intCast(5 * attempt)), .awake) catch {};
                    continue;
                }
                say(io, "dkman: {s}: {s}; skipped (sets kept as they were):", .{ first.repo, describe(err) });
                for (group.items) |g| say(io, " {s}", .{g.set.id});
                say(io, "\n", .{});
                result.failed += group.items.len;
                break;
            }
        }
    }
    return result;
}

/// Downloads one repository into the staging directories of `group` and
/// moves the finished sets into place. Returns the pages installed.
fn installGroup(gpa: Allocator, arena: Allocator, io: Io, env: *const std.process.Environ.Map, root: []const u8, first: *const docsets.Set, group: []Staging) !usize {
    for (group) |*g| {
        g.pages = 0;
        Io.Dir.cwd().deleteTree(io, g.dir) catch {};
        try Io.Dir.cwd().createDirPath(io, g.dir);
    }
    try download(gpa, arena, io, env, first, group);
    var total: usize = 0;
    for (group) |g| {
        if (g.pages == 0) {
            say(io, "dkman: {s}: no pages matched; the repository layout may have changed. Keeping the old copy.\n", .{g.set.id});
            Io.Dir.cwd().deleteTree(io, g.dir) catch {};
            continue;
        }
        try writeManifest(arena, io, g);
        const final = try std.fs.path.join(arena, &.{ root, g.set.id });
        replaceDir(io, g.dir, final) catch |err| {
            if (err == error.NotOurs) say(io, "dkman: {s} exists and was not made by dkman; it is left alone (move it, or use another --docs-dir)\n", .{final});
            return err;
        };
        say(io, "  {s}: {d} pages\n", .{ g.set.id, g.pages });
        total += g.pages;
    }
    return total;
}

/// Moves the finished `staged` directory to `final`, replacing the old copy.
/// On Windows a directory whose files were just written is often still open
/// in a virus scanner or the search indexer for a moment, and deleting or
/// renaming it fails with AccessDenied; that is tried again for a while.
fn replaceDir(io: Io, staged: []const u8, final: []const u8) !void {
    // The documentation directory may hold the user's own files (`E:\docs`):
    // only a set dkman installed (it has a manifest) is ever replaced.
    if (Io.Dir.cwd().openDir(io, final, .{})) |existing| {
        var d = existing;
        defer d.close(io);
        _ = d.statFile(io, manifest_name, .{}) catch return error.NotOurs;
    } else |_| {}
    var tries: usize = 0;
    while (true) : (tries += 1) {
        Io.Dir.cwd().deleteTree(io, final) catch {};
        if (Io.Dir.rename(Io.Dir.cwd(), staged, Io.Dir.cwd(), final, io)) {
            return;
        } else |err| switch (err) {
            error.AccessDenied, error.PermissionDenied, error.FileBusy, error.DirNotEmpty => {
                if (tries >= 20) return err;
                io.sleep(.fromMilliseconds(500), .awake) catch {};
            },
            else => return err,
        }
    }
}

/// A failure that another try may not meet: the network, not the archive's
/// contents or the local disk.
fn retryable(err: anyerror) bool {
    return switch (err) {
        error.HttpStatus, error.NotOurs => false,
        error.AccessDenied, error.PermissionDenied, error.NoSpaceLeft, error.ReadOnlyFileSystem, error.NameTooLong, error.FileBusy => false,
        else => true,
    };
}

fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.HttpStatus => "the server refused the download",
        error.NotOurs => "a directory of the same name is in the way",
        error.BadArchive => "the download broke off or is not a valid archive",
        error.ReadFailed, error.ConnectionResetByPeer, error.EndOfStream => "the connection broke off",
        error.UnknownHostName, error.NetworkUnreachable, error.ConnectionRefused, error.ConnectionTimedOut => "cannot reach github.com (no network?)",
        error.TlsInitializationFailed, error.CertificateBundleLoadFailure => "cannot set up a secure connection",
        error.NoSpaceLeft => "the disk is full",
        error.AccessDenied, error.PermissionDenied, error.FileBusy => "access denied (is a file in use by another program?)",
        else => @errorName(err),
    };
}

fn writeManifest(arena: Allocator, io: Io, g: Staging) !void {
    const text = try std.fmt.allocPrint(arena, "id={s}\ntopic={s}\nversion={s}\ntitle={s}\nrepo={s}\nref={s}\npages={d}\n", .{
        g.set.id, g.set.topic, g.set.version, g.set.title, g.set.repo, g.set.ref, g.pages,
    });
    const path = try std.fs.path.join(arena, &.{ g.dir, manifest_name });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text });
}

/// The path with the archive's top directory (`REPO-REF/`) removed.
fn belowTop(path: []const u8) ?[]const u8 {
    const slash = std.mem.findScalar(u8, path, '/') orelse return null;
    return path[slash + 1 ..];
}

fn download(gpa: Allocator, arena: Allocator, io: Io, env: *const std.process.Environ.Map, first: *const docsets.Set, group: []Staging) !void {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    client.initDefaultProxies(arena, env) catch {};

    const url = try std.fmt.allocPrint(arena, "https://codeload.github.com/{s}/tar.gz/refs/heads/{s}", .{ first.repo, first.ref });
    const uri = try std.Uri.parse(url);
    var req = try client.request(.GET, uri, .{
        // The body is a .tar.gz file, not a compressed transfer.
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
        .extra_headers = &.{.{ .name = "User-Agent", .value = "dkman" }},
    });
    defer req.deinit();
    try req.sendBodiless();
    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);
    if (response.head.status != .ok) return error.HttpStatus;

    var transfer: [4096]u8 = undefined;
    const body = response.reader(&transfer);
    var window: [flate.max_window_len]u8 = undefined;
    var gunzip: flate.Decompress = .init(body, .gzip, &window);

    var name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var link_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var it = std.tar.Iterator.init(&gunzip.reader, .{ .file_name_buffer = &name_buffer, .link_name_buffer = &link_buffer });
    var seen: usize = 0;
    while (true) {
        const file = (it.next() catch return error.BadArchive) orelse break;
        if (file.kind != .file or file.size > max_page_bytes or !std.mem.endsWith(u8, file.name, ".md")) continue;
        const below = belowTop(file.name) orelse continue;
        if (!anyPrefix(group, below)) continue;

        var aw: Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        it.streamRemaining(file, &aw.writer) catch return error.BadArchive;
        const content = aw.written();
        for (group) |*g| {
            var page_arena = std.heap.ArenaAllocator.init(gpa);
            defer page_arena.deinit();
            const target = (try docsets.classify(page_arena.allocator(), g.set, below, content)) orelse continue;
            writePage(page_arena.allocator(), io, g.dir, target, content) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                // A disk that is full or gone ends the download.
                error.NoSpaceLeft, error.FileNotFound => return err,
                // One page that cannot be written (a name the file system
                // refuses, a file another program holds) is left out.
                else => {
                    say(io, "dkman: {s}: page {s} not written: {s}\n", .{ g.set.id, target.name, describe(err) });
                    continue;
                },
            };
            g.pages += 1;
        }
        seen += 1;
        if (seen % 2000 == 0) say(io, "  {d} pages read...\n", .{seen});
    }
}

fn anyPrefix(group: []const Staging, path: []const u8) bool {
    for (group) |g| for (g.set.rules) |r| if (std.mem.startsWith(u8, path, r.prefix)) return true;
    return false;
}

fn writePage(arena: Allocator, io: Io, dir: []const u8, target: docsets.Target, content: []const u8) !void {
    const section_dir = try std.fs.path.join(arena, &.{ dir, try std.fmt.allocPrint(arena, "man{s}", .{target.section}) });
    Io.Dir.cwd().createDirPath(io, section_dir) catch {};
    const file = try std.fs.path.join(arena, &.{ section_dir, try std.fmt.allocPrint(arena, "{s}.{s}.md", .{ target.name, target.section }) });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = content });
}

/// Reports on standard error; a message that cannot be written is dropped.
fn say(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch &buf;
    Io.File.stderr().writeStreamingAll(io, msg) catch {};
}

test "manifest round trip" {
    const info = parseManifest("id=powershell-5.1\ntopic=PowerShell\nversion=5.1\ntitle=T\nrepo=a/b\nref=main\npages=12\n").?;
    try std.testing.expectEqualStrings("powershell-5.1", info.id);
    try std.testing.expectEqualStrings("5.1", info.version);
    try std.testing.expectEqual(@as(usize, 12), info.pages);
    try std.testing.expect(parseManifest("junk\n") == null);
}

test "belowTop drops the archive's top directory" {
    try std.testing.expectEqualStrings("a/b.md", belowTop("PowerShell-Docs-main/a/b.md").?);
    try std.testing.expect(belowTop("file") == null);
}

test "a directory dkman did not make is never replaced" {
    const t = std.testing;
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "docs/.cmd.new/mancmd");
    try tmp.dir.createDirPath(io, "docs/cmd");
    try tmp.dir.writeFile(io, .{ .sub_path = "docs/cmd/mine.txt", .data = "keep" });
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root = try tmp.dir.realPathFileAlloc(io, "docs", a);
    const staged = try std.fs.path.join(a, &.{ root, ".cmd.new" });
    const final = try std.fs.path.join(a, &.{ root, "cmd" });
    try t.expectError(error.NotOurs, replaceDir(io, staged, final));
    _ = try tmp.dir.statFile(io, "docs/cmd/mine.txt", .{});

    // A set dkman installed is replaced.
    try tmp.dir.writeFile(io, .{ .sub_path = "docs/cmd/" ++ manifest_name, .data = "id=cmd\n" });
    try replaceDir(io, staged, final);
    _ = try tmp.dir.statFile(io, "docs/cmd/mancmd", .{});
}

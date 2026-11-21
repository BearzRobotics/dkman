//! The documentation sets `dkman --fetch-docs` can install: Microsoft's
//! documentation repositories (github.com/MicrosoftDocs), which are Markdown
//! files. A set picks pages out of one repository by path and gives each a
//! name and a manual section, so the result is an ordinary manual directory
//! (`SET/manps/Get-ChildItem.ps.md`) that every dkman mode already searches.
//!
//! Sets that share a repository are installed from one download.
//!
//! Sections: `ps` cmdlets and about topics, `cmd` Windows commands, `ws`
//! Windows Server guides, `psguide` PowerShell guides, `sys` Sysinternals,
//! `wsl`, `win32` API reference, `winguide` Win32 and COM guides.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Naming = enum {
    /// The file name without `.md`; `index`, `toc` and `README` are skipped.
    stem,
    /// The folder path below the prefix joined with `-` (`ad-ds-plan-foo`);
    /// an `index` page is named after its folder. For guides, whose file
    /// names alone repeat.
    slug,
    /// The Win32 reference: the name in the page's `UID:` front matter
    /// (`NF:fileapi.CreateFileA` is `CreateFileA`); other pages are skipped.
    uid,
};

pub const Rule = struct {
    /// Path below the repository's top directory, ending in `/`.
    prefix: []const u8,
    naming: Naming,
    section: []const u8,
    /// Folders below `prefix` that belong to another rule.
    exclude: []const []const u8 = &.{},
};

pub const Set = struct {
    id: []const u8,
    /// `owner/name` on GitHub.
    repo: []const u8,
    ref: []const u8 = "main",
    /// What it is about, for grouping (`PowerShell`, `Windows Server`).
    topic: []const u8,
    /// The product version the pages describe, or "" when there is one.
    version: []const u8 = "",
    title: []const u8,
    rules: []const Rule,
};

/// Approximate size of a repository's download, in megabytes (what GitHub
/// reports for the repository; the archive of the current files is smaller).
pub const Repo = struct { name: []const u8, mb: u32 };
pub const repos = [_]Repo{
    .{ .name = "MicrosoftDocs/PowerShell-Docs", .mb = 104 },
    .{ .name = "MicrosoftDocs/windows-powershell-docs", .mb = 85 },
    .{ .name = "MicrosoftDocs/windowsserverdocs", .mb = 1013 },
    .{ .name = "MicrosoftDocs/sysinternals", .mb = 6 },
    .{ .name = "MicrosoftDocs/WSL", .mb = 52 },
    .{ .name = "MicrosoftDocs/PowerShell-Docs-Modules", .mb = 38 },
    .{ .name = "MicrosoftDocs/win32", .mb = 420 },
    .{ .name = "MicrosoftDocs/sdk-api", .mb = 1157 },
    .{ .name = "MicrosoftDocs/office-docs-powershell", .mb = 122 },
    .{ .name = "MicrosoftDocs/OfficeDocs-SharePoint-PowerShell", .mb = 13 },
    .{ .name = "MicrosoftDocs/PowerShell-Docs-DSC", .mb = 3 },
    .{ .name = "MicrosoftDocs/PowerShell-Docs-PSGet", .mb = 1 },
};

pub fn repoSize(name: []const u8) u32 {
    for (repos) |r| if (std.mem.eql(u8, r.name, name)) return r.mb;
    return 0;
}

const ps_docs = "MicrosoftDocs/PowerShell-Docs";
const ws_docs = "MicrosoftDocs/windowsserverdocs";
const office = "MicrosoftDocs/office-docs-powershell";
const dsc = "MicrosoftDocs/PowerShell-Docs-DSC";
const psget = "MicrosoftDocs/PowerShell-Docs-PSGet";

fn psVersion(comptime v: []const u8) Set {
    return .{
        .id = "powershell-" ++ v,
        .repo = ps_docs,
        .topic = "PowerShell",
        .version = v,
        .title = "PowerShell " ++ v ++ ": cmdlets and about topics",
        .rules = &.{.{ .prefix = "reference/" ++ v ++ "/", .naming = .stem, .section = "ps" }},
    };
}

fn winps(comptime year: []const u8) Set {
    return .{
        .id = "winps-" ++ year,
        .repo = "MicrosoftDocs/windows-powershell-docs",
        .topic = "Windows Server",
        .version = year,
        .title = "Windows Server " ++ year ++ " PowerShell modules (Hyper-V, ActiveDirectory, DnsServer, NetAdapter, ...)",
        .rules = &.{.{ .prefix = "docset/winserver" ++ year ++ "-ps/", .naming = .stem, .section = "ps" }},
    };
}

fn dscVersion(comptime v: []const u8) Set {
    return .{
        .id = "dsc-" ++ v,
        .repo = dsc,
        .topic = "DSC",
        .version = v,
        .title = "Desired State Configuration " ++ v ++ ": cmdlets, resources and guides",
        .rules = &.{
            .{ .prefix = "dsc/dsc-" ++ v ++ "/", .naming = .stem, .section = "ps" },
            .{ .prefix = "dsc/docs-conceptual/dsc-" ++ v ++ "/", .naming = .slug, .section = "psguide" },
        },
    };
}

pub const all = [_]Set{
    psVersion("5.1"),
    psVersion("7.4"),
    psVersion("7.5"),
    psVersion("7.6"),
    psVersion("7.7"),
    .{
        .id = "powershell-guide",
        .repo = ps_docs,
        .topic = "PowerShell",
        .title = "PowerShell guides: learning, scripting, language reference, SDK",
        .rules = &.{.{ .prefix = "reference/docs-conceptual/", .naming = .slug, .section = "psguide" }},
    },
    .{
        .id = "psmodules",
        .repo = "MicrosoftDocs/PowerShell-Docs-Modules",
        .topic = "PowerShell",
        .title = "PowerShell team modules: PSScriptAnalyzer, SecretManagement, PlatyPS, Crescendo",
        .rules = &.{
            .{ .prefix = "reference/ps-modules/", .naming = .stem, .section = "ps" },
            .{ .prefix = "reference/docs-conceptual/", .naming = .slug, .section = "psguide" },
        },
    },
    winps("2016"),
    winps("2019"),
    winps("2022"),
    winps("2025"),
    .{
        .id = "cmd",
        .repo = ws_docs,
        .topic = "Windows Server",
        .title = "Windows commands (cmd.exe and the command-line tools)",
        .rules = &.{.{ .prefix = "WindowsServerDocs/administration/windows-commands/", .naming = .stem, .section = "cmd" }},
    },
    .{
        .id = "winserver",
        .repo = ws_docs,
        .topic = "Windows Server",
        .title = "Windows Server guides: AD DS, AD FS, DNS, Hyper-V, remote access, Admin Center, storage, performance",
        .rules = &.{.{
            .prefix = "WindowsServerDocs/",
            .naming = .slug,
            .section = "ws",
            .exclude = &.{"administration/windows-commands/"},
        }},
    },
    .{
        .id = "sysinternals",
        .repo = "MicrosoftDocs/sysinternals",
        .topic = "Sysinternals",
        .title = "Sysinternals tools",
        .rules = &.{.{ .prefix = "sysinternals/downloads/", .naming = .stem, .section = "sys" }},
    },
    .{
        .id = "wsl",
        .repo = "MicrosoftDocs/WSL",
        .topic = "WSL",
        .title = "Windows Subsystem for Linux",
        .rules = &.{.{ .prefix = "WSL/", .naming = .stem, .section = "wsl" }},
    },
    .{
        .id = "win32",
        .repo = "MicrosoftDocs/sdk-api",
        .ref = "docs",
        .topic = "Win32 API",
        .title = "Win32 API reference: functions, methods, structures, enumerations, callbacks, interfaces",
        .rules = &.{.{ .prefix = "sdk-api-src/content/", .naming = .uid, .section = "win32" }},
    },
    .{
        .id = "win32-guide",
        .repo = "MicrosoftDocs/win32",
        .ref = "docs",
        .topic = "Win32 API",
        .title = "Win32 and COM programming guides and overviews (desktop-src)",
        .rules = &.{.{ .prefix = "desktop-src/", .naming = .slug, .section = "winguide" }},
    },
    .{
        .id = "exchange",
        .repo = office,
        .topic = "Microsoft 365",
        .title = "Exchange and Exchange Online PowerShell",
        .rules = &.{.{ .prefix = "exchange/exchange-ps/ExchangePowerShell/", .naming = .stem, .section = "ps" }},
    },
    .{
        .id = "teams",
        .repo = office,
        .topic = "Microsoft 365",
        .title = "Microsoft Teams PowerShell",
        .rules = &.{.{ .prefix = "teams/teams-ps/MicrosoftTeams/", .naming = .stem, .section = "ps" }},
    },
    .{
        .id = "skype",
        .repo = office,
        .topic = "Microsoft 365",
        .title = "Skype for Business PowerShell",
        .rules = &.{.{ .prefix = "skype/skype-ps/SkypeForBusiness/", .naming = .stem, .section = "ps" }},
    },
    .{
        .id = "office-misc",
        .repo = office,
        .topic = "Microsoft 365",
        .title = "Office Web Apps, Whiteboard, SharePoint Migration Tool and Ink Canvas PowerShell",
        .rules = &.{
            .{ .prefix = "officewebapps/officewebapps-ps/officewebapps/", .naming = .stem, .section = "ps" },
            .{ .prefix = "whiteboard/whiteboard-ps/WhiteboardAdmin/", .naming = .stem, .section = "ps" },
            .{ .prefix = "spmt/spmt-ps/Microsoft.SharePoint.MigrationTool.PowerShell/", .naming = .stem, .section = "ps" },
            .{ .prefix = "inkcanvas/inkcanvas-ps/InkCanvasAdmin/", .naming = .stem, .section = "ps" },
        },
    },
    .{
        .id = "sharepoint-online",
        .repo = "MicrosoftDocs/OfficeDocs-SharePoint-PowerShell",
        .topic = "Microsoft 365",
        .title = "SharePoint Online PowerShell",
        .rules = &.{.{ .prefix = "sharepoint/sharepoint-ps/Microsoft.Online.SharePoint.PowerShell/", .naming = .stem, .section = "ps" }},
    },
    .{
        .id = "sharepoint-server",
        .repo = "MicrosoftDocs/OfficeDocs-SharePoint-PowerShell",
        .topic = "SharePoint Server",
        .title = "SharePoint Server PowerShell",
        .rules = &.{
            .{ .prefix = "sharepoint/sharepoint-ps/Microsoft.SharePoint.Powershell/", .naming = .stem, .section = "ps" },
            .{ .prefix = "sharepoint/sharepoint-server-ps/SharePointServer/", .naming = .stem, .section = "ps" },
        },
    },
    dscVersion("1.1"),
    dscVersion("2.0"),
    dscVersion("3.0"),
    .{
        .id = "psget-2.x",
        .repo = psget,
        .topic = "PowerShell Gallery",
        .version = "2.x",
        .title = "PowerShellGet 2.x and PackageManagement",
        .rules = &.{.{ .prefix = "powershell-gallery/powershellget-2.x/", .naming = .stem, .section = "ps" }},
    },
    .{
        .id = "psget-3.x",
        .repo = psget,
        .topic = "PowerShell Gallery",
        .version = "3.x",
        .title = "Microsoft.PowerShell.PSResourceGet 3.x",
        .rules = &.{.{ .prefix = "powershell-gallery/powershellget-3.x/", .naming = .stem, .section = "ps" }},
    },
    .{
        .id = "psget-guide",
        .repo = psget,
        .topic = "PowerShell Gallery",
        .title = "PowerShell Gallery guides",
        .rules = &.{.{ .prefix = "powershell-gallery/docs-conceptual/", .naming = .slug, .section = "psguide" }},
    },
};

pub fn find(id: []const u8) ?*const Set {
    for (&all) |*s| if (std.mem.eql(u8, s.id, id)) return s;
    return null;
}

/// Does `word` select the set whose id, topic and version are given? An id
/// (`powershell-5.1`), the start of one before a dash (`powershell`), a
/// topic (`windows server`) or a version (`5.1`, `2022`) does.
pub fn matches(id: []const u8, topic: []const u8, version: []const u8, word: []const u8) bool {
    if (word.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(id, word)) return true;
    if (id.len > word.len and id[word.len] == '-' and std.ascii.eqlIgnoreCase(id[0..word.len], word)) return true;
    if (std.ascii.eqlIgnoreCase(topic, word)) return true;
    return version.len > 0 and std.ascii.eqlIgnoreCase(version, word);
}

// ---------------------------------------------------------------- classifying

/// A page chosen for a set: its manual section and name, in the arena.
pub const Target = struct { section: []const u8, name: []const u8 };

/// Characters a page name may have; anything else (spaces, `%`, non-ASCII)
/// would not survive as a file name on every system, so the page is skipped.
fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 120 or name[0] == '.') return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-' and c != '.' and c != '+') return false;
    }
    return true;
}

fn isSkipStem(stem: []const u8) bool {
    for ([_][]const u8{ "index", "toc", "readme" }) |s| if (std.ascii.eqlIgnoreCase(stem, s)) return true;
    return false;
}

/// The value of `key:` in a Markdown file's front matter.
pub fn frontMatterValue(content: []const u8, key: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, content, "---")) return null;
    var lines = std.mem.splitScalar(u8, content, '\n');
    _ = lines.next();
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.eql(u8, line, "---") or std.mem.eql(u8, line, "...")) return null;
        if (std.mem.startsWith(u8, line, key) and line.len > key.len and line[key.len] == ':') {
            const v = std.mem.trim(u8, line[key.len + 1 ..], " \t\"'");
            return if (v.len > 0) v else null;
        }
    }
    return null;
}

fn uidName(arena: Allocator, content: []const u8) Allocator.Error!?[]const u8 {
    const uid = frontMatterValue(content, "UID") orelse return null;
    // Functions, structures, enumerations and callbacks; the rest is concept.
    inline for (.{ "NF:", "NM:", "NS:", "NE:", "NC:", "NI:" }) |kind| {
        if (std.mem.startsWith(u8, uid, kind)) {
            const rest = uid[kind.len..];
            // An interface (`NI:unknwn.IUnknown`) and the like have a header and a name.
            const dot = std.mem.findScalar(u8, rest, '.') orelse return null;
            // `fileapi.CreateFileA` is `CreateFileA`; `unknwn.IUnknown.QueryInterface`
            // keeps its interface: `IUnknown.QueryInterface`.
            return try arena.dupe(u8, rest[dot + 1 ..]);
        }
    }
    return null;
}

fn slugName(arena: Allocator, rel: []const u8) Allocator.Error!?[]const u8 {
    var path = rel[0 .. rel.len - 3];
    if (std.mem.endsWith(u8, path, "/index")) path = path[0 .. path.len - 6] else if (std.mem.eql(u8, path, "index")) return null;
    const out = try arena.dupe(u8, path);
    for (out) |*c| {
        if (c.* == '/') c.* = '-';
    }
    return out;
}

/// What `tar_path` (below the repository's top directory) becomes in `set`,
/// or null when the set does not take it. `content` is the file's text.
pub fn classify(arena: Allocator, set: *const Set, tar_path: []const u8, content: []const u8) Allocator.Error!?Target {
    if (!std.mem.endsWith(u8, tar_path, ".md")) return null;
    for (set.rules) |rule| {
        if (!std.mem.startsWith(u8, tar_path, rule.prefix)) continue;
        const rel = tar_path[rule.prefix.len..];
        var excluded = false;
        for (rule.exclude) |ex| {
            if (std.mem.startsWith(u8, rel, ex)) excluded = true;
        }
        if (excluded) continue;
        const name: ?[]const u8 = switch (rule.naming) {
            .stem => blk: {
                const base = std.fs.path.basename(rel);
                const stem = base[0 .. base.len - 3];
                break :blk if (isSkipStem(stem)) null else try arena.dupe(u8, stem);
            },
            .slug => try slugName(arena, rel),
            .uid => try uidName(arena, content),
        };
        const n = name orelse return null;
        if (!validName(n)) return null;
        return .{ .section = rule.section, .name = n };
    }
    return null;
}

test "every set names a known repository and ends its prefixes with a slash" {
    const t = std.testing;
    for (all) |s| {
        try t.expect(repoSize(s.repo) > 0);
        try t.expect(s.rules.len > 0);
        for (s.rules) |r| try t.expect(std.mem.endsWith(u8, r.prefix, "/"));
        var same: usize = 0;
        for (all) |o| same += @intFromBool(std.mem.eql(u8, o.id, s.id));
        try t.expectEqual(@as(usize, 1), same);
    }
}

test "classify cmdlets, guides and API pages" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const ps = find("powershell-5.1").?;
    const c = (try classify(a, ps, "reference/5.1/Microsoft.PowerShell.Management/Get-ChildItem.md", "")).?;
    try t.expectEqualStrings("ps", c.section);
    try t.expectEqualStrings("Get-ChildItem", c.name);
    const about = (try classify(a, ps, "reference/5.1/Microsoft.PowerShell.Core/About/about_Arrays.md", "")).?;
    try t.expectEqualStrings("about_Arrays", about.name);
    try t.expect(try classify(a, ps, "reference/7.6/Microsoft.PowerShell.Management/Get-ChildItem.md", "") == null);
    try t.expect(try classify(a, ps, "reference/5.1/Microsoft.PowerShell.Management/index.md", "") == null);
    try t.expect(try classify(a, ps, "reference/5.1/docfx.json", "") == null);

    const cmd = find("cmd").?;
    try t.expectEqualStrings("netsh-add", (try classify(a, cmd, "WindowsServerDocs/administration/windows-commands/netsh-add.md", "")).?.name);

    // The guides leave the commands to `cmd`, and are named by their folders.
    const ws = find("winserver").?;
    try t.expect(try classify(a, ws, "WindowsServerDocs/administration/windows-commands/dir.md", "") == null);
    const g = (try classify(a, ws, "WindowsServerDocs/identity/ad-ds/plan/ad-ds-design-and-planning.md", "")).?;
    try t.expectEqualStrings("ws", g.section);
    try t.expectEqualStrings("identity-ad-ds-plan-ad-ds-design-and-planning", g.name);
    try t.expectEqualStrings("networking-dns", (try classify(a, ws, "WindowsServerDocs/networking/dns/index.md", "")).?.name);
    try t.expect(try classify(a, ws, "WindowsServerDocs/index.md", "") == null);

    const w32 = find("win32").?;
    try t.expectEqualStrings("CreateFileA", (try classify(a, w32, "sdk-api-src/content/fileapi/nf-fileapi-createfilea.md", "---\nUID: NF:fileapi.CreateFileA\ntitle: x\n---\n")).?.name);
    const front = "---\ntitle: CreateFileA function\nUID: NF:fileapi.CreateFileA\n---\n# x\n";
    try t.expectEqualStrings("CreateFileA", (try classify(a, w32, "sdk-api-src/content/fileapi/nf-fileapi-createfilea.md", front)).?.name);
    const method = "---\nUID: NF:unknwn.IUnknown.QueryInterface\n---\n";
    try t.expectEqualStrings("IUnknown.QueryInterface", (try classify(a, w32, "sdk-api-src/content/x/y.md", method)).?.name);
    try t.expect(try classify(a, w32, "sdk-api-src/content/x/overview.md", "---\ntitle: Overview\n---\n") == null);
    try t.expect(try classify(a, w32, "sdk-api-src/content/x/s.md", "---\nUID: NS:wdm.FOO\n---\n") != null);
}

test "matches by id, family, topic and version" {
    const t = std.testing;
    try t.expect(matches("powershell-5.1", "PowerShell", "5.1", "powershell-5.1"));
    try t.expect(matches("powershell-5.1", "PowerShell", "5.1", "powershell"));
    try t.expect(matches("powershell-5.1", "PowerShell", "5.1", "5.1"));
    try t.expect(matches("winps-2022", "Windows Server", "2022", "2022"));
    try t.expect(matches("cmd", "Windows Server", "", "windows server"));
    try t.expect(!matches("powershell-5.1", "PowerShell", "5.1", "power"));
    try t.expect(!matches("cmd", "Windows Server", "", ""));
}

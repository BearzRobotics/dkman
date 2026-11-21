//! dkman: find, search and show manual pages and Markdown documents.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const paths = @import("paths.zig");
const page_mod = @import("page.zig");
const tui = @import("tui.zig");
const render = @import("render.zig");
const pager = @import("pager.zig");
const search = @import("search.zig");
const whatis = @import("whatis.zig");
const console = @import("console.zig");
const platform = @import("platform.zig");
const docsets = @import("docsets.zig");
const fetch = @import("fetch.zig");

const usage =
    \\usage: dkman [options] [SECTION] NAME...
    \\       dkman [options] -l FILE...
    \\       dkman -f NAME...        (whatis)
    \\       dkman -k WORD...        (apropos)
    \\       dkman -b [WORD]         (browse)
    \\
    \\  -s, -S LIST      only these sections (colon or comma separated, in this order)
    \\  -a, --all        show every matching page (with -k: all words must match)
    \\  -I, --match-case  page names are case sensitive (default: ignore case)
    \\  -e, --extension E  only pages of this extension (the `perl` of 3perl)
    \\  -H, --html       write HTML instead of text
    \\  -l, --local-file show a file (a path, or - for standard input)
    \\  -w, --where      print the path of the page instead of showing it
    \\  -f, --whatis     one-line descriptions of the pages called NAME
    \\  -k, --apropos    pages whose name or description contains a WORD
    \\  -K, --global-apropos  pages whose text contains a WORD
    \\  -r, --regex      with -f/-k: words are regular expressions (-k default)
    \\  --wildcard       with -f/-k: words are shell wildcards
    \\  --exact          with -k: words must equal a name or a word of the description
    \\  -b, --browse     browse pages: search on the left, preview on the right (names and descriptions)
    \\  -M, --manpath P  manual directories (colon separated, semicolon on Windows) instead of $MANPATH
    \\  --set LIST       only the downloaded documentation sets named by LIST: an id (powershell-5.1),
    \\                   a family (powershell), a topic (windows server) or a version (5.1)
    \\  --docs-dir DIR   where downloaded documentation is kept and searched (default: per user;
    \\                   or $DKMAN_DOCS), for example a folder on a USB drive
    \\  --list-docs      list the documentation sets that can be downloaded, and which are
    \\  --fetch-docs SET...  download documentation sets from Microsoft's GitHub (or `all`)
    \\  -L, --locale L   language of the pages (default from LC_ALL, LC_MESSAGES, LANG)
    \\  -P, --pager CMD  pager command (default: $MANPAGER, $PAGER, less; more on Windows)
    \\  --width N        wrap at N columns (default: $MANWIDTH, $COLUMNS, the terminal, 80)
    \\  --nj             do not justify the text (right margin ragged)
    \\  --ascii          ASCII characters only (default unless the locale is UTF-8)
    \\  --color          always use ANSI styles
    \\  --no-color       no ANSI styles (also when not on a terminal or NO_COLOR is set)
    \\  --no-pager       write to standard output
    \\  --update-index   rebuild the cache of page descriptions
    \\  -V, --version    print the version
    \\  -h, --help       this text
    \\
;

/// Exit codes of man-db: 0 success, 1 usage or syntax, 2 operation failed,
/// 16 no page found.
const exit_usage: u8 = 1;
const exit_failed: u8 = 2;
const exit_not_found: u8 = 16;

const Mode = enum { show, local, where, whatis, apropos, global_apropos, browse, update_index, version, list_docs, fetch_docs };

const Config = struct {
    mode: Mode = .show,
    width: ?usize = null,
    /// null: decide from the terminal.
    color: ?bool = null,
    ascii: ?bool = null,
    pager: bool = true,
    pager_cmd: ?[]const u8 = null,
    all: bool = false,
    /// mandb -q: no output.
    quiet: bool = false,
    /// --nj: leave the right margin ragged.
    justify: bool = true,
    /// whatis -l / apropos -l: do not cut lines to the terminal width.
    long: bool = false,
    match_case: bool = false,
    extension: ?[]const u8 = null,
    html: bool = false,
    /// With -f/-k: how words are compared; null is the mode's default.
    match: ?whatis.Mode = null,
    manpath: ?[]const u8 = null,
    /// `--docs-dir`: where the downloaded documentation sets are.
    docs_dir: ?[]const u8 = null,
    /// `--set`: only these downloaded documentation sets.
    doc_set: ?[]const u8 = null,
    locale: ?[]const u8 = null,
    /// From `-s`: the sections to look in, in order.
    sections: []const []const u8 = &.{},
    /// A leading section operand (`dkman 3 printf`).
    section: ?[]const u8 = null,
    words: []const []const u8 = &.{},
};

const ParseError = error{ Usage, Unsupported };

const Opt = enum { no_justify, long_lines, unsupported, match_case, ignore_case, extension, html, regex, wildcard, exact, local, where, whatis, apropos, global, browse, all, sections, manpath, pager, locale, width, color, no_color, no_pager, ascii, update_index, version, help, ignored, list_docs, fetch_docs, doc_set, docs_dir };

const OptSpec = struct { short: u8 = 0, long: []const u8 = "", opt: Opt, value: bool = false };

const option_table = [_]OptSpec{
    .{ .short = 'l', .long = "local-file", .opt = .local },
    .{ .short = 'w', .long = "where", .opt = .where },
    .{ .long = "path", .opt = .where },
    .{ .short = 'f', .long = "whatis", .opt = .whatis },
    .{ .short = 'k', .long = "apropos", .opt = .apropos },
    .{ .short = 'K', .long = "global-apropos", .opt = .global },
    .{ .short = 'b', .long = "browse", .opt = .browse },
    .{ .short = 'a', .long = "all", .opt = .all },
    .{ .short = 'I', .long = "match-case", .opt = .match_case },
    .{ .short = 'i', .long = "ignore-case", .opt = .ignore_case },
    .{ .short = 'e', .long = "extension", .opt = .extension, .value = true },
    .{ .short = 'H', .long = "html", .opt = .html },
    .{ .short = 'r', .long = "regex", .opt = .regex },
    .{ .long = "wildcard", .opt = .wildcard },
    .{ .long = "exact", .opt = .exact },
    .{ .short = 's', .long = "sections", .opt = .sections, .value = true },
    .{ .short = 'S', .opt = .sections, .value = true },
    .{ .short = 'M', .long = "manpath", .opt = .manpath, .value = true },
    .{ .short = 'P', .long = "pager", .opt = .pager, .value = true },
    .{ .short = 'L', .long = "locale", .opt = .locale, .value = true },
    .{ .long = "width", .opt = .width, .value = true },
    .{ .long = "color", .opt = .color },
    .{ .long = "no-color", .opt = .no_color },
    .{ .long = "no-pager", .opt = .no_pager },
    .{ .short = '7', .long = "ascii", .opt = .ascii },
    .{ .long = "update-index", .opt = .update_index },
    .{ .long = "list-docs", .opt = .list_docs },
    .{ .long = "fetch-docs", .opt = .fetch_docs },
    .{ .long = "set", .opt = .doc_set, .value = true },
    .{ .long = "docs-dir", .opt = .docs_dir, .value = true },
    .{ .short = 'V', .long = "version", .opt = .version },
    .{ .short = 'h', .long = "help", .opt = .help },
    .{ .short = '?', .long = "usage", .opt = .help },
    // Accepted for compatibility with man(1); dkman does not hyphenate or justify.
    .{ .long = "nh", .opt = .ignored },
    .{ .long = "nj", .opt = .no_justify },
    .{ .short = 'E', .long = "encoding", .opt = .ignored, .value = true },
    .{ .short = 'C', .long = "config-file", .opt = .ignored, .value = true },
    .{ .short = 'm', .long = "systems", .opt = .ignored, .value = true },
    .{ .short = 'd', .long = "debug", .opt = .ignored },
    .{ .short = 'D', .opt = .ignored },
    .{ .short = 'c', .long = "catman", .opt = .ignored },
    .{ .short = 'u', .opt = .ignored },
    // Typeset output (troff, PostScript) is not something dkman can make.
    .{ .short = 't', .long = "troff", .opt = .unsupported },
    .{ .short = 'T', .long = "troff-device", .opt = .unsupported, .value = true },
};

/// Which command the program was started as: dkman, man, or one of the
/// companions man-db installs as separate commands.
const Prog = enum { man, whatis, apropos, manpath, mandb };

fn progOf(argv0: []const u8) Prog {
    var base = std.fs.path.basename(argv0);
    // `man.exe`, `WHATIS.EXE`.
    if (base.len > 4 and std.ascii.eqlIgnoreCase(base[base.len - 4 ..], ".exe")) base = base[0 .. base.len - 4];
    inline for (.{ "whatis", "apropos", "manpath", "mandb" }) |name| {
        if (std.mem.eql(u8, base, name)) return @field(Prog, name);
    }
    return .man;
}

fn lookupShort(prog: Prog, c: u8) ?OptSpec {
    // whatis(1) and apropos(1) use some letters differently from man(1).
    if (prog == .whatis or prog == .apropos) switch (c) {
        'w' => return .{ .short = 'w', .long = "wildcard", .opt = .wildcard },
        'e' => return .{ .short = 'e', .long = "exact", .opt = .exact },
        'l' => return .{ .short = 'l', .long = "long", .opt = .long_lines },
        else => {},
    };
    for (option_table) |o| if (o.short == c) return o;
    return null;
}

fn lookupLong(name: []const u8) ?OptSpec {
    for (option_table) |o| if (o.long.len > 0 and std.mem.eql(u8, o.long, name)) return o;
    return null;
}

fn parseArgs(arena: Allocator, args: []const [:0]const u8) (ParseError || Allocator.Error)!Config {
    var cfg: Config = .{};
    const prog = progOf(args[0]);
    switch (prog) {
        .man => {},
        .whatis => cfg.mode = .whatis,
        .apropos => cfg.mode = .apropos,
        // These two take options of their own that dkman has no use for; only
        // the version and help requests mean anything.
        .manpath, .mandb => {
            cfg.mode = if (prog == .manpath) .where else .update_index;
            for (args[1..]) |a| {
                if (std.mem.eql(u8, a, "-q") or std.mem.eql(u8, a, "--quiet")) cfg.quiet = true;
                if (std.mem.eql(u8, a, "-V") or std.mem.eql(u8, a, "--version")) cfg.mode = .version;
                if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-?")) return error.Usage;
            }
            return cfg;
        },
    }
    var words: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    var only_words = false;
    while (i < args.len) : (i += 1) {
        const a: []const u8 = args[i];
        if (only_words or a.len < 2 or a[0] != '-') {
            try words.append(arena, a);
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            only_words = true;
            continue;
        }
        if (a[1] == '-') {
            const eq = std.mem.findScalar(u8, a, '=');
            const spec = lookupLong(a[2 .. eq orelse a.len]) orelse return error.Usage;
            var value: ?[]const u8 = if (eq) |e| a[e + 1 ..] else null;
            if (spec.value and value == null) {
                i += 1;
                if (i >= args.len) return error.Usage;
                value = args[i];
            } else if (!spec.value and value != null) return error.Usage;
            try apply(&cfg, spec.opt, value);
            continue;
        }
        // A cluster of short options: `-aw`, `-s3`, `-s 3`.
        var j: usize = 1;
        while (j < a.len) : (j += 1) {
            const spec = lookupShort(prog, a[j]) orelse return error.Usage;
            if (spec.value) {
                var value: []const u8 = a[j + 1 ..];
                if (value.len == 0) {
                    i += 1;
                    if (i >= args.len) return error.Usage;
                    value = args[i];
                }
                try apply(&cfg, spec.opt, value);
                break;
            }
            try apply(&cfg, spec.opt, null);
        }
    }
    // `dkman 3 printf`: a leading section number before the page name.
    if ((cfg.mode == .show or cfg.mode == .where) and words.items.len >= 2 and isSection(words.items[0])) {
        cfg.section = words.items[0];
        words.items = words.items[1..];
    }
    cfg.words = words.items;
    return cfg;
}

fn apply(cfg: *Config, opt: Opt, value: ?[]const u8) (ParseError || Allocator.Error)!void {
    switch (opt) {
        .local => cfg.mode = .local,
        .where => cfg.mode = .where,
        .whatis => cfg.mode = .whatis,
        .apropos => cfg.mode = .apropos,
        .global => cfg.mode = .global_apropos,
        .browse => cfg.mode = .browse,
        .update_index => cfg.mode = .update_index,
        .list_docs => cfg.mode = .list_docs,
        .fetch_docs => cfg.mode = .fetch_docs,
        .doc_set => cfg.doc_set = value,
        .docs_dir => cfg.docs_dir = value,
        .version => cfg.mode = .version,
        .all => cfg.all = true,
        .match_case => cfg.match_case = true,
        .ignore_case => cfg.match_case = false,
        .extension => cfg.extension = value,
        .html => cfg.html = true,
        .regex => cfg.match = .regex,
        .wildcard => cfg.match = .wildcard,
        .exact => cfg.match = .exact,
        .sections => cfg.sections = try splitList(value.?),
        .manpath => cfg.manpath = value,
        .pager => cfg.pager_cmd = value,
        .locale => cfg.locale = value,
        .width => cfg.width = std.fmt.parseInt(usize, value.?, 10) catch return error.Usage,
        .color => cfg.color = true,
        .no_color => cfg.color = false,
        .no_pager => cfg.pager = false,
        .ascii => cfg.ascii = true,
        .help => return error.Usage,
        .ignored => {},
        .long_lines => cfg.long = true,
        .no_justify => cfg.justify = false,
        .unsupported => return error.Unsupported,
    }
}

/// Section lists are short; split into a fixed buffer owned by the process.
var list_storage: [32][]const u8 = undefined;
fn splitList(text: []const u8) ParseError![]const []const u8 {
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, text, ":, \t");
    while (it.next()) |w| {
        if (n == list_storage.len) return error.Usage;
        list_storage[n] = w;
        n += 1;
    }
    return list_storage[0..n];
}

/// Sections of the downloaded documentation sets (see `docsets.zig`).
const doc_sections = [_][]const u8{ "ps", "cmd", "ws", "psguide", "sys", "wsl", "win32", "winguide" };

fn isSection(s: []const u8) bool {
    for (doc_sections) |d| if (std.mem.eql(u8, s, d)) return true;
    return s.len > 0 and s.len <= 4 and (std.ascii.isDigit(s[0]) or s[0] == 'n' or s[0] == 'l') and
        std.ascii.isAlphanumeric(s[s.len - 1]);
}

/// `MANOPT` holds options that come before the command line's own, as in
/// man-db. Only for the `man` command: the companions have other options.
fn withManopt(arena: Allocator, args: []const [:0]const u8, manopt: ?[]const u8) Allocator.Error![]const [:0]const u8 {
    const text = manopt orelse return args;
    if (args.len == 0 or progOf(args[0]) != .man) return args;
    var out: std.ArrayList([:0]const u8) = .empty;
    try out.append(arena, args[0]);
    var it = std.mem.tokenizeAny(u8, text, " \t");
    while (it.next()) |w| try out.append(arena, try arena.dupeSentinel(u8, w, 0));
    try out.appendSlice(arena, args[1..]);
    return out.items;
}

/// Everything the modes share.
const Ctx = struct {
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    dirs: []const []const u8,
    /// The manual directories without the locale's, for `-w` alone.
    base_dirs: []const []const u8,
    /// Order sections are tried in.
    order: []const []const u8,
    opts: render.Options,
    /// Page names are compared ignoring case (man-db's default; -I turns it off).
    ignore_case: bool,
    use_pager: bool,
    pager_cmd: []const u8,
    /// Where the page index is kept, system-wide first (read first, written first
    /// when possible), then the user's.
    cache_files: []const []const u8,
    /// The user's documentation folder (`--docs-dir`), read for loose pages.
    loose: ?whatis.Loose = null,
};

pub fn main(init: std.process.Init) !u8 {
    return run(init) catch |err| switch (err) {
        // `dkman ls | head`: the reader went away; that is not a failure.
        error.BrokenPipe => 0,
        else => |e| e,
    };
}

fn run(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const env = init.environ_map;
    const given = try init.minimal.args.toSlice(arena);
    const args = try withManopt(arena, given, init.environ_map.get("MANOPT"));

    var cfg = parseArgs(arena, args) catch |err| switch (err) {
        error.Usage => {
            try Io.File.stderr().writeStreamingAll(io, usage);
            return exit_usage;
        },
        error.Unsupported => {
            try diag(io, "dkman: typeset output (-t, -T) is not supported\n", .{});
            return exit_usage;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };

    if (cfg.mode == .version) {
        try printLine(io, "dkman " ++ build_options.version);
        return 0;
    }

    const stdout_tty = Io.File.stdout().isTty(io) catch false;
    const no_color_env = if (env.get("NO_COLOR")) |v| v.len > 0 else false;
    // On Windows the console must be told to understand ANSI styles and UTF-8;
    // an old console that cannot gets plain text.
    const console_ready = if (stdout_tty) console.prepareOutput() else true;
    const use_color = cfg.color orelse (stdout_tty and console_ready and !no_color_env);
    const opts: render.Options = .{
        .width = cfg.width orelse try widthFor(env, stdout_tty),
        .color = use_color,
        // Windows consoles show UTF-8 once set up; a pipe or file may be read in any code page.
        .ascii = cfg.ascii orelse !(utf8Locale(env) or (stdout_tty and console_ready and console.outputIsUtf8Console())),
        .html = cfg.html,
        .justify = cfg.justify,
    };

    // The documentation directory: --docs-dir, DKMAN_DOCS, else the per-user one.
    const docs_arg = cfg.docs_dir orelse nonEmpty(env.get("DKMAN_DOCS"));
    // A directory about to be filled must exist to be made absolute (the page
    // index is keyed by the directory's name).
    if (docs_arg != null and cfg.mode == .fetch_docs) Io.Dir.cwd().createDirPath(io, docs_arg.?) catch {};
    const docs_dir: ?[]const u8 = if (docs_arg) |d| try platform.absolute(arena, io, d) else null;
    if (cfg.mode == .list_docs) return runListDocs(gpa, arena, io, env, docs_dir);
    // A fetch in which some sets failed still indexes the ones installed.
    var fetch_status: u8 = 0;
    if (cfg.mode == .fetch_docs) {
        fetch_status = try runFetchDocs(gpa, arena, io, env, cfg, docs_dir);
        if (fetch_status != 0 and fetch_status != exit_failed) return fetch_status;
        // Build the page index now (it can take half a minute for everything),
        // not at the first search.
        cfg.mode = .update_index;
        cfg.quiet = false;
        cfg.doc_set = null;
        try diag(io, "dkman: building the page index...\n", .{});
    }

    // Manual directories: -M, MANPATH, or derived from PATH and the config file;
    // the downloaded documentation sets and, on Windows, the usual places of
    // man pages are always searched when MANPATH does not say otherwise.
    const conf = try readConf(arena, io, env);
    var derived_list: std.ArrayList([]const u8) = .empty;
    try derived_list.appendSlice(arena, try paths.deriveManpath(arena, io, env.get("PATH"), conf));
    if (builtin.os.tag == .windows) try derived_list.appendSlice(arena, try platform.windowsManDirs(arena, io, env));
    try derived_list.appendSlice(arena, try platform.docDirs(arena, io, env, docs_dir));
    var base_dirs = try paths.searchDirs(arena, cfg.manpath orelse env.get("MANPATH"), derived_list.items);
    // `--set`: only the downloaded sets it names.
    if (cfg.doc_set) |sel| {
        base_dirs = try selectSets(arena, io, env, sel, docs_dir);
        if (base_dirs.len == 0) {
            try diag(io, "dkman: no downloaded documentation set matches {s} (see dkman --list-docs)\n", .{sel});
            return exit_not_found;
        }
    }
    const dirs = try paths.withLocale(arena, base_dirs, cfg.locale orelse localeFromEnv(env));

    const order: []const []const u8 = if (cfg.sections.len > 0)
        cfg.sections
    else if (nonEmpty(env.get("MANSECT"))) |ms|
        try paths.parseSections(arena, ms)
    else if (conf.sections.len > 0)
        conf.sections
    else
        &paths.default_sections;

    // The user's own pages in the documentation folder, unless `--set` or
    // `-M`/MANPATH narrowed the search.
    const loose: ?whatis.Loose = if (docs_dir != null and cfg.doc_set == null and cfg.manpath == null and nonEmpty(env.get("MANPATH")) == null)
        try looseDocs(arena, io, docs_dir.?)
    else
        null;

    const ctx: Ctx = .{
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .dirs = dirs,
        .base_dirs = base_dirs,
        .order = order,
        .opts = opts,
        .ignore_case = !cfg.match_case,
        .use_pager = cfg.pager and stdout_tty and !cfg.html,
        .pager_cmd = cfg.pager_cmd orelse nonEmpty(env.get("MANPAGER")) orelse nonEmpty(env.get("PAGER")) orelse platform.default_pager,
        .cache_files = try cacheFiles(arena, io, env, dirs, loose, docs_dir),
        .loose = loose,
    };

    const status = try switch (cfg.mode) {
        .version, .list_docs, .fetch_docs => unreachable,
        .local => runLocal(ctx, cfg),
        .show, .where => runShow(ctx, cfg),
        .whatis, .apropos => runWhatis(ctx, cfg),
        .global_apropos => runGlobal(ctx, cfg),
        .update_index => runUpdate(ctx, cfg),
        .browse => runBrowse(ctx, cfg),
    };
    return if (status == 0) fetch_status else status;
}

// ------------------------------------------------------------------- modes

fn runLocal(ctx: Ctx, cfg: Config) !u8 {
    if (cfg.words.len == 0) return usageError(ctx.io);
    var status: u8 = 0;
    for (cfg.words) |w| {
        const text = try renderPath(ctx, w) orelse {
            status = exit_failed;
            continue;
        };
        defer ctx.gpa.free(text);
        try display(ctx, text);
    }
    return status;
}

fn runShow(ctx: Ctx, cfg: Config) !u8 {
    if (cfg.words.len == 0) {
        // `man -w` alone: where the pages are looked for.
        if (cfg.mode == .where) {
            try printLine(ctx.io, try std.mem.join(ctx.arena, &.{platform.list_separator}, ctx.base_dirs));
            return 0;
        }
        return usageError(ctx.io);
    }
    var status: u8 = 0;
    for (cfg.words) |arg| {
        // A name with a slash is a path, as with man(1).
        if (platform.looksLikePath(arg)) {
            if (cfg.mode == .where) {
                try printLine(ctx.io, arg);
            } else if (try renderPath(ctx, arg)) |text| {
                defer ctx.gpa.free(text);
                try display(ctx, text);
            } else status = exit_failed;
            continue;
        }
        const ns = paths.splitNameSection(arg);
        const section = cfg.section orelse ns.section;
        const wanted: []const []const u8 = if (cfg.sections.len > 0) cfg.sections else if (section) |sec| &.{sec} else &.{};
        var found: []const paths.Page = try paths.findAll(ctx.arena, ctx.io, ctx.dirs, ns.name, wanted, ctx.order, ctx.ignore_case);
        if (cfg.extension) |ext| found = try withExtension(ctx.arena, found, ext);
        // No file of that name: a page may declare the name in its NAME line.
        if (found.len == 0 and cfg.extension == null) found = try declaredNames(ctx, ns.name, wanted);
        if (found.len == 0) {
            if (wanted.len == 1) {
                try diag(ctx.io, "No manual entry for {s} in section {s}\n", .{ ns.name, wanted[0] });
            } else try diag(ctx.io, "No manual entry for {s}\n", .{ns.name});
            try suggestNames(ctx, ns.name);
            status = exit_not_found;
            continue;
        }
        var chosen = if (cfg.all) found else found[0..1];
        // Pages that only redirect (links, `.so`) stand for their target, as in man-db.
        if (cfg.mode == .where or cfg.all) chosen = try resolveRedirects(ctx, chosen);
        if (cfg.mode == .where) {
            for (chosen) |pg| try printLine(ctx.io, pg.path);
            continue;
        }
        // One page at a time, each in its own pager: leaving one shows the next.
        for (chosen) |pg| {
            const text = try renderPath(ctx, pg.path) orelse {
                status = exit_failed;
                continue;
            };
            defer ctx.gpa.free(text);
            try display(ctx, text);
        }
    }
    return status;
}

/// Pages whose NAME line declares `name` (`isastream` in `unimplemented.2`),
/// from the index, in the order pages are preferred.
fn declaredNames(ctx: Ctx, name: []const u8, sections: []const []const u8) ![]const paths.Page {
    const entries = try loadIndex(ctx, false);
    const hits = try whatis.lookup(ctx.arena, entries, name, .exact, ctx.ignore_case, sections);
    var pages: std.ArrayList(paths.Page) = .empty;
    for (hits) |e| {
        var seen = false;
        for (pages.items) |p| if (std.mem.eql(u8, p.path, e.path)) {
            seen = true;
        };
        if (!seen) try pages.append(ctx.arena, .{ .name = e.name, .section = e.section, .path = e.path, .dir_index = 0 });
    }
    paths.sortByPreference(pages.items, if (sections.len > 0) sections else ctx.order);
    return pages.items;
}

/// Replaces each page by the file its symbolic link or `.so` redirects lead to, and drops
/// repeats. A page that cannot be read stays as it is.
fn resolveRedirects(ctx: Ctx, pages: []const paths.Page) ![]const paths.Page {
    var out: std.ArrayList(paths.Page) = .empty;
    for (pages) |pg| {
        var final = pg;
        final.path = try paths.followLinks(ctx.arena, ctx.io, pg.path);
        if (page_mod.load(ctx.gpa, ctx.arena, ctx.io, ctx.dirs, final.path)) |loaded| {
            defer loaded.deinit(ctx.gpa);
            final.path = try ctx.arena.dupe(u8, loaded.path);
        } else |_| {}
        var seen = false;
        for (out.items) |p| if (std.mem.eql(u8, p.path, final.path)) {
            seen = true;
        };
        if (!seen) try out.append(ctx.arena, final);
    }
    return out.items;
}

/// Pages whose section carries the extension: `perl` keeps `3perl`.
fn withExtension(arena: Allocator, pages: []const paths.Page, ext: []const u8) Allocator.Error![]const paths.Page {
    var out: std.ArrayList(paths.Page) = .empty;
    for (pages) |p| {
        if (p.section.len > 1 and std.ascii.eqlIgnoreCase(p.section[1..], ext)) try out.append(arena, p);
    }
    return out.items;
}

/// After a miss: pages with a similar name, on standard error.
fn suggestNames(ctx: Ctx, name: []const u8) !void {
    const pages = try paths.scan(ctx.arena, ctx.io, ctx.dirs, null, null, false);
    const names = try search.suggest(ctx.arena, pages, name, 5);
    if (names.len == 0) return;
    try diag(ctx.io, "Did you mean: {s}?\n", .{try std.mem.join(ctx.arena, ", ", names)});
}

fn loadIndex(ctx: Ctx, force: bool) ![]whatis.Entry {
    const loaded = try whatis.load(ctx.gpa, ctx.arena, ctx.io, ctx.dirs, ctx.loose, ctx.cache_files, force, "dkman: building the page index (first use, or the manual directories changed)...\n");
    return loaded.entries;
}

fn runWhatis(ctx: Ctx, cfg: Config) !u8 {
    if (cfg.words.len == 0) return usageError(ctx.io);
    const entries = try loadIndex(ctx, false);
    const sections = cfg.sections;
    if (cfg.mode == .apropos) {
        const hits = try whatis.oneEach(ctx.arena, try whatis.keywords(ctx.arena, entries, cfg.words, cfg.all, cfg.match orelse .regex, sections));
        if (hits.len == 0) {
            try diag(ctx.io, "{s}: nothing appropriate.\n", .{cfg.words[0]});
            return exit_not_found;
        }
        const text = try whatis.listing(ctx.gpa, hits, if (cfg.long) 0 else ctx.opts.width);
        defer ctx.gpa.free(text);
        try display(ctx, text);
        return 0;
    }
    var status: u8 = 0;
    for (cfg.words) |w| {
        const name = paths.splitNameSection(w);
        const secs: []const []const u8 = if (name.section) |s| &.{s} else sections;
        const hits = try whatis.oneEach(ctx.arena, try whatis.lookup(ctx.arena, entries, name.name, cfg.match orelse .exact, ctx.ignore_case, secs));
        if (hits.len == 0) {
            try diag(ctx.io, "{s}: nothing appropriate.\n", .{name.name});
            status = exit_not_found;
            continue;
        }
        const text = try whatis.listing(ctx.gpa, hits, if (cfg.long) 0 else ctx.opts.width);
        defer ctx.gpa.free(text);
        try pager.writeStdout(ctx.io, text);
    }
    return status;
}

/// `-K`: pages whose text contains every word, found by reading them all.
fn runGlobal(ctx: Ctx, cfg: Config) !u8 {
    if (cfg.words.len == 0) return usageError(ctx.io);
    const pages = try paths.scan(ctx.arena, ctx.io, ctx.dirs, null, null, false);
    search.sortByName(pages);
    var hits: std.ArrayList(paths.Page) = .empty;
    for (pages) |pg| {
        if (cfg.sections.len > 0) {
            var ok = false;
            for (cfg.sections) |s| {
                if (std.mem.startsWith(u8, pg.section, s)) ok = true;
            }
            if (!ok) continue;
        }
        var scratch_state = std.heap.ArenaAllocator.init(ctx.gpa);
        defer scratch_state.deinit();
        const text = page_mod.renderFile(ctx.gpa, scratch_state.allocator(), ctx.io, ctx.dirs, pg.path, .{ .width = 0 }) catch continue;
        defer ctx.gpa.free(text);
        var all_found = true;
        for (cfg.words) |w| {
            if (std.ascii.findIgnoreCase(text, w) == null) all_found = false;
        }
        if (all_found) try hits.append(ctx.arena, pg);
    }
    if (hits.items.len == 0) {
        try diag(ctx.io, "{s}: nothing appropriate.\n", .{cfg.words[0]});
        return exit_not_found;
    }
    const menu = try search.menuText(ctx.gpa, hits.items);
    defer ctx.gpa.free(menu);
    try display(ctx, menu);
    return 0;
}

fn runUpdate(ctx: Ctx, cfg: Config) !u8 {
    const loaded = try whatis.load(ctx.gpa, ctx.arena, ctx.io, ctx.dirs, ctx.loose, ctx.cache_files, true, null);
    const to = loaded.written_to orelse {
        try diag(ctx.io, "dkman: cannot write the page index to {s}\n", .{try std.mem.join(ctx.arena, " or ", ctx.cache_files)});
        return exit_failed;
    };
    if (!cfg.quiet) try printLine(ctx.io, try std.fmt.allocPrint(ctx.arena, "{d} pages indexed in {s}", .{ loaded.entries.len, to }));
    return 0;
}

fn runBrowse(ctx: Ctx, cfg: Config) !u8 {
    var page_list: std.ArrayList(paths.Page) = .empty;
    try page_list.appendSlice(ctx.arena, try paths.scan(ctx.arena, ctx.io, ctx.dirs, null, null, false));
    if (ctx.loose) |l| try page_list.appendSlice(ctx.arena, try paths.scanLoose(ctx.arena, ctx.io, l.root, l.skip));
    const pages = page_list.items;
    if (pages.len == 0) {
        try diag(ctx.io, "dkman: no manual pages found in the search path\n", .{});
        return exit_not_found;
    }
    search.sortByName(pages);
    // Descriptions from the cached index let the search look beyond names.
    const descriptions = try describePages(ctx, pages);
    var query: []const u8 = if (cfg.words.len > 0) try std.mem.join(ctx.arena, " ", cfg.words) else "";
    var select: ?[]const u8 = null;
    var status: u8 = 0;
    // Back to the browser after each page, with the same search.
    while (true) {
        const chosen = tui.run(ctx.gpa, ctx.io, ctx.dirs, pages, .{ .color = ctx.opts.color, .query = query, .select = select, .descriptions = descriptions }) catch |err| switch (err) {
            error.NotATerminal => {
                try diag(ctx.io, "dkman: -b needs a terminal; use dkman -k WORD instead\n", .{});
                return exit_failed;
            },
            else => |e| return e,
        } orelse return status;
        defer ctx.gpa.free(chosen.path);
        defer ctx.gpa.free(chosen.query);
        query = try ctx.arena.dupe(u8, chosen.query);
        select = try ctx.arena.dupe(u8, chosen.path);
        if (try renderPath(ctx, chosen.path)) |text| {
            defer ctx.gpa.free(text);
            try display(ctx, text);
            status = 0;
        } else status = exit_failed;
        if (!ctx.use_pager) return status;
    }
}

/// The description of each page, from the index, in the order of `pages`.
fn describePages(ctx: Ctx, pages: []const paths.Page) ![]const []const u8 {
    const entries = try loadIndex(ctx, false);
    var by_path: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (entries) |e| {
        if (e.description.len > 0) try by_path.put(ctx.arena, e.path, e.description);
    }
    const out = try ctx.arena.alloc([]const u8, pages.len);
    for (pages, out) |pg, *d| d.* = by_path.get(pg.path) orelse "";
    return out;
}

// ----------------------------------------------------------------- helpers

fn usageError(io: Io) !u8 {
    try Io.File.stderr().writeStreamingAll(io, usage);
    return exit_usage;
}

fn nonEmpty(s: ?[]const u8) ?[]const u8 {
    const v = s orelse return null;
    return if (v.len > 0) v else null;
}

/// Line length: `MANWIDTH`, `COLUMNS`, the terminal's width, else 80.
fn widthFor(env: *const std.process.Environ.Map, tty: bool) !usize {
    for ([_][]const u8{ "MANWIDTH", "COLUMNS" }) |name| {
        if (nonEmpty(env.get(name))) |v| {
            const n = std.fmt.parseInt(usize, v, 10) catch continue;
            if (n >= 20 and n <= 1000) return n;
        }
    }
    if (tty) {
        const cols = tui.terminalSize().cols;
        if (cols >= 20 and cols <= 1000) return cols;
    }
    return 80;
}

fn localeFromEnv(env: *const std.process.Environ.Map) ?[]const u8 {
    for ([_][]const u8{ "LC_ALL", "LC_MESSAGES", "LANG" }) |name| {
        if (nonEmpty(env.get(name))) |v| return v;
    }
    return null;
}

/// True when the locale's character set is UTF-8.
fn utf8Locale(env: *const std.process.Environ.Map) bool {
    for ([_][]const u8{ "LC_ALL", "LC_CTYPE", "LANG" }) |name| {
        if (nonEmpty(env.get(name))) |v| {
            return std.ascii.findIgnoreCase(v, "utf-8") != null or std.ascii.findIgnoreCase(v, "utf8") != null;
        }
    }
    return false;
}

fn readConf(arena: Allocator, io: Io, env: *const std.process.Environ.Map) !paths.Conf {
    for (try platform.configFiles(arena, env)) |f| {
        const text = Io.Dir.cwd().readFileAlloc(io, f, arena, .limited(1 << 20)) catch continue;
        return paths.parseConf(arena, text);
    }
    return .{};
}

/// Name of the file in the documentation folder listing folders (one per
/// line, below the folder; `#` starts a comment) not to read loose pages from.
const ignore_file = ".dkmanignore";

/// The user's documentation folder `root` as a source of loose pages: its
/// `.dkmanignore` folders and dkman's own subdirectory are left out.
fn looseDocs(arena: Allocator, io: Io, root: []const u8) !whatis.Loose {
    var skip: std.ArrayList([]const u8) = .empty;
    try skip.append(arena, platform.sets_subdir);
    const path = try std.fs.path.join(arena, &.{ root, ignore_file });
    if (Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024))) |text| {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            try skip.append(arena, line);
        }
    } else |_| {}
    return .{ .root = root, .skip = skip.items };
}

/// Where the page index lives, one file per set of manual directories: the
/// system-wide cache (made by `mandb` run as root or administrator, read by
/// everyone), then the user's.
fn cacheFiles(arena: Allocator, io: Io, env: *const std.process.Environ.Map, dirs: []const []const u8, loose: ?whatis.Loose, docs_dir: ?[]const u8) ![]const []const u8 {
    var hash = std.hash.Wyhash.init(0);
    for (dirs) |d| {
        hash.update(d);
        hash.update(";");
    }
    if (loose) |l| {
        hash.update("loose:");
        hash.update(l.root);
    }
    const name = try std.fmt.allocPrint(arena, "whatis-{x}", .{hash.final()});
    var out: std.ArrayList([]const u8) = .empty;
    // With a documentation directory of one's own (a USB drive) the index is
    // kept there first, beside the sets: it travels with the docs and the
    // host is left alone.
    if (docs_dir != null) {
        if (try platform.docsRoot(arena, io, env, docs_dir)) |d| try out.append(arena, try std.fs.path.join(arena, &.{ d, ".cache", name }));
    }
    for (try platform.cacheDirs(arena, env)) |d| try out.append(arena, try std.fs.path.join(arena, &.{ d, name }));
    return out.items;
}

// ------------------------------------------------------ documentation sets

/// The downloaded sets `selector` (comma separated) names, as manual directories.
fn selectSets(arena: Allocator, io: Io, env: *const std.process.Environ.Map, selector: []const u8, docs_dir: ?[]const u8) ![]const []const u8 {
    const root = (try platform.docsRoot(arena, io, env, docs_dir)) orelse return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (try fetch.installed(arena, io, root)) |info| {
        var words = std.mem.tokenizeAny(u8, selector, ",");
        while (words.next()) |w| {
            if (docsets.matches(info.id, info.topic, info.version, std.mem.trim(u8, w, " \t"))) {
                try out.append(arena, try std.fs.path.join(arena, &.{ root, info.id }));
                break;
            }
        }
    }
    return out.items;
}

fn runListDocs(gpa: Allocator, arena: Allocator, io: Io, env: *const std.process.Environ.Map, docs_dir: ?[]const u8) !u8 {
    _ = gpa;
    const root = try platform.docsRoot(arena, io, env, docs_dir);
    const have = if (root) |r| try fetch.installed(arena, io, r) else &[_]fetch.Info{};
    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "{s:<20} {s:<20} {s:<8} {s:>9}  {s}\n", .{ "SET", "TOPIC", "VERSION", "DOWNLOAD", "CONTENTS" });
    for (docsets.all) |set| {
        var status: []const u8 = "";
        for (have) |h| if (std.mem.eql(u8, h.id, set.id)) {
            status = try std.fmt.allocPrint(arena, " [installed, {d} pages]", .{h.pages});
        };
        try out.print(arena, "{s:<20} {s:<20} {s:<8} {d:>6} MB  {s}{s}\n", .{ set.id, set.topic, set.version, docsets.repoSize(set.repo), set.title, status });
    }
    try out.print(arena, "\nDownload with: dkman --fetch-docs SET... (or a family such as powershell, a topic or a version; all for everything).\nSets of one repository share a download, which is of the whole repository; only Markdown pages are kept.\n", .{});
    if (root) |r| try out.print(arena, "Installed in {s}\n", .{r});
    try pager.writeStdout(io, out.items);
    return 0;
}

fn runFetchDocs(gpa: Allocator, arena: Allocator, io: Io, env: *const std.process.Environ.Map, cfg: Config, docs_dir: ?[]const u8) !u8 {
    if (cfg.words.len == 0) {
        try diag(io, "dkman: name the sets to download; dkman --list-docs shows them\n", .{});
        return exit_usage;
    }
    const root = (try platform.docsRoot(arena, io, env, docs_dir)) orelse {
        try diag(io, "dkman: cannot tell where to keep documentation (no LOCALAPPDATA, XDG_DATA_HOME or HOME)\n", .{});
        return exit_failed;
    };
    var chosen: std.ArrayList(*const docsets.Set) = .empty;
    for (cfg.words) |w| {
        var any = false;
        for (&docsets.all) |*set| {
            if (!std.ascii.eqlIgnoreCase(w, "all") and !docsets.matches(set.id, set.topic, set.version, w)) continue;
            any = true;
            var dup = false;
            for (chosen.items) |c| if (c == set) {
                dup = true;
            };
            if (!dup) try chosen.append(arena, set);
        }
        if (!any) {
            try diag(io, "dkman: no documentation set called {s} (see dkman --list-docs)\n", .{w});
            return exit_usage;
        }
    }
    const result = try fetch.install(gpa, arena, io, env, root, chosen.items);
    try printLine(io, try std.fmt.allocPrint(arena, "{d} pages installed in {s}; the page index follows", .{ result.pages, root }));
    if (result.failed > 0) {
        try diag(io, "dkman: {d} of {d} sets could not be downloaded (see above); run the same command again to retry them\n", .{ result.failed, chosen.items.len });
        return exit_failed;
    }
    return 0;
}

fn printLine(io: Io, s: []const u8) !void {
    try pager.writeStdout(io, s);
    try pager.writeStdout(io, "\n");
}

fn diag(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch &buf;
    try Io.File.stderr().writeStreamingAll(io, msg);
}

/// Loads and renders one file (`-` is standard input). Returns null after
/// reporting an error to stderr; the caller owns the text.
fn renderPath(ctx: Ctx, path: []const u8) !?[]u8 {
    return page_mod.renderFile(ctx.gpa, ctx.arena, ctx.io, ctx.dirs, path, ctx.opts) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BrokenRedirect => {
            try diag(ctx.io, "dkman: {s} redirects to a page that was not found\n", .{path});
            return null;
        },
        error.FileNotFound => {
            try diag(ctx.io, "dkman: {s}: no such file\n", .{path});
            return null;
        },
        else => {
            try diag(ctx.io, "dkman: cannot show {s}: {s}\n", .{ path, @errorName(err) });
            return null;
        },
    };
}

fn display(ctx: Ctx, text: []const u8) !void {
    if (ctx.use_pager) try pager.show(ctx.gpa, ctx.io, ctx.pager_cmd, text) else try pager.writeStdout(ctx.io, text);
}

test {
    _ = @import("paths.zig");
    _ = @import("format.zig");
    _ = @import("source.zig");
    _ = @import("page.zig");
    _ = @import("tui.zig");
    _ = @import("render.zig");
    _ = @import("pager.zig");
    _ = @import("search.zig");
    _ = @import("theme.zig");
    _ = @import("whatis.zig");
    _ = @import("bzip2.zig");
    _ = @import("glob.zig");
    _ = @import("platform.zig");
    _ = @import("docsets.zig");
    _ = @import("fetch.zig");
    _ = @import("console.zig");
}

test "argument parsing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const t = std.testing;

    const c1 = try parseArgs(a, &.{ "dkman", "3", "printf" });
    try t.expectEqualStrings("3", c1.section.?);
    try t.expectEqual(@as(usize, 1), c1.words.len);

    // A documentation section before a name; alone it is a page name.
    const cs = try parseArgs(a, &.{ "dkman", "ps", "Get-Item" });
    try t.expectEqualStrings("ps", cs.section.?);
    try t.expect((try parseArgs(a, &.{ "dkman", "ps" })).section == null);

    // A single number is a page name, not a section.
    const c2 = try parseArgs(a, &.{ "dkman", "7" });
    try t.expect(c2.section == null);

    const c3 = try parseArgs(a, &.{ "dkman", "--width", "60", "--no-pager", "-l", "x.md" });
    try t.expectEqual(@as(usize, 60), c3.width.?);
    try t.expectEqual(Mode.local, c3.mode);
    try t.expect(!c3.pager);

    // Clusters, attached and separate values, long options with `=`.
    const c4 = try parseArgs(a, &.{ "dkman", "-aw", "-s3:2", "ls" });
    try t.expect(c4.all);
    try t.expectEqual(Mode.where, c4.mode);
    try t.expectEqual(@as(usize, 2), c4.sections.len);
    try t.expectEqualStrings("2", c4.sections[1]);
    const c5 = try parseArgs(a, &.{ "dkman", "-M", "/a:/b", "--pager=cat", "--locale", "de", "ls" });
    try t.expectEqualStrings("/a:/b", c5.manpath.?);
    try t.expectEqualStrings("cat", c5.pager_cmd.?);
    try t.expectEqualStrings("de", c5.locale.?);
    const c6 = try parseArgs(a, &.{ "dkman", "-f", "ls" });
    try t.expectEqual(Mode.whatis, c6.mode);
    try t.expectEqual(Mode.apropos, (try parseArgs(a, &.{ "dkman", "-k", "x" })).mode);
    try t.expectEqual(Mode.browse, (try parseArgs(a, &.{ "dkman", "-b" })).mode);
    try t.expectEqual(Mode.version, (try parseArgs(a, &.{ "dkman", "-V" })).mode);
    // `--` ends the options; a lone `-` is a word (standard input).
    const c7 = try parseArgs(a, &.{ "dkman", "-l", "--", "-", "-x" });
    try t.expectEqual(@as(usize, 2), c7.words.len);

    // Companion commands, by the name they are started under.
    try t.expectEqual(Mode.whatis, (try parseArgs(a, &.{ "/usr/bin/whatis", "ls" })).mode);
    try t.expectEqual(Mode.apropos, (try parseArgs(a, &.{ "apropos", "-a", "x", "y" })).mode);
    const w = try parseArgs(a, &.{ "apropos", "-w", "x*" });
    try t.expectEqual(whatis.Mode.wildcard, w.match.?);
    try t.expectEqual(whatis.Mode.exact, (try parseArgs(a, &.{ "whatis", "-e", "x" })).match.?);
    try t.expectEqual(Mode.where, (try parseArgs(a, &.{ "manpath", "-q" })).mode);
    try t.expectEqual(Mode.update_index, (try parseArgs(a, &.{ "mandb", "-q", "-C", "x" })).mode);
    try t.expectEqual(Mode.version, (try parseArgs(a, &.{ "mandb", "--version" })).mode);
    try t.expect((try parseArgs(a, &.{ "mandb", "-q" })).quiet);
    try t.expect((try parseArgs(a, &.{ "whatis", "-l", "x" })).long);
    // Options that do nothing here are accepted; typeset output is refused.
    const c8 = try parseArgs(a, &.{ "man", "-d", "-C", "conf", "-mfoo", "-c", "ls" });
    try t.expectEqual(@as(usize, 1), c8.words.len);
    try t.expectError(error.Unsupported, parseArgs(a, &.{ "man", "-t", "ls" }));
    try t.expectError(error.Unsupported, parseArgs(a, &.{ "man", "-Tps", "ls" }));

    try t.expectError(error.Usage, parseArgs(a, &.{ "dkman", "--bogus" }));
    try t.expectError(error.Usage, parseArgs(a, &.{ "dkman", "-Z" }));
    try t.expectError(error.Usage, parseArgs(a, &.{ "dkman", "--width" }));
    try t.expectError(error.Usage, parseArgs(a, &.{ "dkman", "--width", "x" }));
    try t.expectError(error.Usage, parseArgs(a, &.{ "dkman", "-s" }));
    try t.expectError(error.Usage, parseArgs(a, &.{ "dkman", "--all=1" }));
}

test "MANOPT goes before the arguments, for man only" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const out = try withManopt(a, &.{ "man", "ls" }, " -a  -s 3 ");
    try std.testing.expectEqual(@as(usize, 5), out.len);
    try std.testing.expectEqualStrings("-a", out[1]);
    try std.testing.expectEqualStrings("ls", out[4]);
    try std.testing.expectEqual(@as(usize, 2), (try withManopt(a, &.{ "whatis", "ls" }, "-a")).len);
    try std.testing.expectEqual(@as(usize, 2), (try withManopt(a, &.{ "man", "ls" }, null)).len);
}

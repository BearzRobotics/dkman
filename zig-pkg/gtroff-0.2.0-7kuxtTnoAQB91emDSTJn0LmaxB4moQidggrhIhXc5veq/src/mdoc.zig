//! Reader for BSD mdoc(7) pages. Builds the same md-zig tree as `man.zig`.
//!
//! mdoc is a semantic macro language: `.Fl a` is "a flag", not "bold". The
//! reader keeps the parts that matter for reading a page on a terminal:
//! sections, paragraphs, lists (`.Bl`/`.It`/`.El`), displays (`.Bd`/`.Dl`),
//! the inline macros (callable macros are nested and take punctuation as
//! mdoc(7) describes), function synopses, references and the text macros
//! (`.Ex`, `.Rv`, `.St`, `.At`, `.Bx`, ...).
//!
//! Not supported (silently skipped): `.Sm`/`.Db` spacing modes, `.Bk`, column
//! widths and offsets, `.Eo`/`.Ec` custom delimiters, `.Hf`, `.Tg`.

const std = @import("std");
const md = @import("md");
const Allocator = std.mem.Allocator;
const Node = md.Node;
const escape = @import("escape.zig");
const Font = escape.Font;

const max_levels = 16;

const Word = struct { text: []const u8, quoted: bool = false };

/// Macros that can appear inside the arguments of another macro.
const Callable = enum {
    Ac,
    Ad,
    An,
    Ao,
    Ap,
    Aq,
    Ar,
    At,
    Bc,
    Bo,
    Bq,
    Brc,
    Bro,
    Brq,
    Bsx,
    Bx,
    Cd,
    Cm,
    Dc,
    Do,
    Dq,
    Dv,
    Dx,
    Ec,
    Em,
    En,
    Eo,
    Er,
    Es,
    Ev,
    Fa,
    Fc,
    Fd,
    Fl,
    Fn,
    Fo,
    Fr,
    Ft,
    Fx,
    Ic,
    In,
    Lb,
    Li,
    Lk,
    Ms,
    Mt,
    Nm,
    No,
    Ns,
    Nx,
    Ok,
    Oc,
    Oo,
    Op,
    Ot,
    Ox,
    Pa,
    Pc,
    Pf,
    Po,
    Pq,
    Qc,
    Ql,
    Qo,
    Qq,
    Sc,
    So,
    Sq,
    St,
    Sx,
    Sy,
    Ta,
    Tn,
    Ud,
    Ux,
    Va,
    Vt,
    Xc,
    Xo,
    Xr,
};

/// Macros that start a line and are not nested.
const Block = enum {
    Bd,
    Bf,
    Bk,
    Bl,
    Db,
    Dd,
    Dl,
    D1,
    Dt,
    Ed,
    Ef,
    Ek,
    El,
    Ex,
    Hf,
    It,
    Lp,
    Nd,
    Os,
    Pp,
    Re,
    Rs,
    Rv,
    Sh,
    Sm,
    Ss,
    Tg,
    @"%A",
    @"%B",
    @"%C",
    @"%D",
    @"%I",
    @"%J",
    @"%N",
    @"%O",
    @"%P",
    @"%Q",
    @"%R",
    @"%T",
    @"%U",
    @"%V",
};

const ListKind = enum { tag, bullet, enumerated, column };

const Ctx = struct {
    kind: ListKind,
    /// The `deflist`, `list` or `table` node.
    list: *Node,
    /// Where blocks were added before the list started.
    parent: *Node,
    item_open: bool = false,
};

const Reference = struct {
    authors: std.ArrayList([]const u8) = .empty,
    title: []const u8 = "",
    book: []const u8 = "",
    journal: []const u8 = "",
    volume: []const u8 = "",
    number: []const u8 = "",
    pages: []const u8 = "",
    publisher: []const u8 = "",
    city: []const u8 = "",
    date: []const u8 = "",
    report: []const u8 = "",
    institution: []const u8 = "",
    optional: []const u8 = "",
    url: []const u8 = "",
};

const Parser = struct {
    a: Allocator,
    root: *Node,
    st: escape.State = .{},

    cur: *Node,
    para: ?*Node = null,
    /// Where inline output goes (paragraph, list term, table cell, link).
    target: *Node,
    stack: [max_levels]Ctx = undefined,
    depth: usize = 0,

    /// A space is due before the next word.
    space: bool = false,
    nm: []const u8 = "",
    synopsis: bool = false,
    base_font: Font = .roman,
    in_fo: bool = false,
    fo_first: bool = true,
    /// The last run written by `emit`, so that neighbours in one font merge.
    last_top: ?*Node = null,
    last_leaf: ?*Node = null,
    last_font: Font = .roman,

    bd_literal: bool = false,
    code: std.ArrayList(u8) = .empty,
    xo: ?std.ArrayList(Word) = null,
    xo_depth: usize = 0,
    rs: ?Reference = null,
    line_no: u32 = 0,

    fn node(self: *Parser, kind: md.Kind) Allocator.Error!*Node {
        const n = try self.a.create(Node);
        n.* = .{ .kind = kind, .line = self.line_no };
        n.build.open = false;
        return n;
    }

    // ---- output helpers ----------------------------------------------------

    fn addRun(self: *Parser, parent: *Node, text: []const u8, font: Font) Allocator.Error!void {
        _ = try self.addRunTracked(parent, text, font);
    }

    const Added = struct { top: *Node, leaf: *Node };

    fn addRunTracked(self: *Parser, parent: *Node, text: []const u8, font: Font) Allocator.Error!Added {
        var inner = try self.node(if (font.mono) .code else .text);
        const leaf = inner;
        inner.literal = try self.a.dupe(u8, text);
        if (font.italic and !font.mono) {
            const e = try self.node(.emph);
            e.appendChild(inner);
            inner = e;
        }
        if (font.bold and !font.mono) {
            const s = try self.node(.strong);
            s.appendChild(inner);
            inner = s;
        }
        parent.appendChild(inner);
        return .{ .top = inner, .leaf = leaf };
    }

    /// Writes already escaped `text` to the target, with a leading space if one
    /// is due and `glue_before` is false. `glue_after` keeps the next word
    /// attached (after an opening bracket).
    fn emit(self: *Parser, text: []const u8, font: Font, glue_before: bool, glue_after: bool) Allocator.Error!void {
        if (text.len == 0) return;
        const lead = self.space and !glue_before;
        const f: Font = if (font.eql(.roman)) self.base_font else font;
        if (self.last_leaf) |leaf| {
            if (self.target.last_child == self.last_top and self.last_font.eql(f)) {
                leaf.literal = try std.mem.concat(self.a, u8, &.{ leaf.literal, if (lead) " " else "", text });
                self.space = !glue_after;
                return;
            }
        }
        if (lead) try self.addRun(self.target, " ", .roman);
        const added = try self.addRunTracked(self.target, text, f);
        self.last_top = added.top;
        self.last_leaf = added.leaf;
        self.last_font = f;
        self.space = !glue_after;
    }

    fn clean(self: *Parser, w: []const u8) Allocator.Error![]const u8 {
        return escape.plain(self.a, &self.st, w);
    }

    fn isOpening(w: Word) bool {
        return !w.quoted and (std.mem.eql(u8, w.text, "(") or std.mem.eql(u8, w.text, "["));
    }

    fn isClosing(w: Word) bool {
        if (w.quoted) return false;
        for ([_][]const u8{ ".", ",", ":", ";", ")", "]", "?", "!" }) |d| if (std.mem.eql(u8, w.text, d)) return true;
        return false;
    }

    fn isCallable(w: Word) bool {
        return !w.quoted and std.meta.stringToEnum(Callable, w.text) != null;
    }

    /// Index of the first callable macro at or after `start`.
    fn argsEnd(words: []const Word, start: usize) usize {
        var i = start;
        while (i < words.len) : (i += 1) if (isCallable(words[i])) return i;
        return words.len;
    }

    fn endPara(self: *Parser) void {
        self.para = null;
    }

    /// The paragraph that receives inline text; created on demand.
    fn paragraph(self: *Parser) Allocator.Error!*Node {
        if (self.para) |p| return p;
        const p = try self.node(.paragraph);
        self.cur.appendChild(p);
        self.para = p;
        return p;
    }

    fn lineSep(self: *Parser, hard: bool) Allocator.Error!void {
        const p = self.para orelse return;
        if (self.target != p) return;
        if (p.last_child) |last| {
            if (last.kind == .softbreak or last.kind == .linebreak) return;
            p.appendChild(try self.node(if (hard) .linebreak else .softbreak));
        }
    }

    // ---- word parsing --------------------------------------------------------

    /// One plain word: punctuation sticks to its neighbours.
    fn plainWord(self: *Parser, w: Word) Allocator.Error!void {
        const t = try self.clean(w.text);
        if (isOpening(w)) return self.emit(t, .roman, false, true);
        if (isClosing(w)) return self.emit(t, .roman, true, false);
        try self.emit(t, .roman, false, false);
    }

    /// Words as macros and text, left to right.
    fn parse(self: *Parser, words: []const Word) Allocator.Error!void {
        var i: usize = 0;
        while (i < words.len) {
            const w = words[i];
            if (isCallable(w)) {
                i = try self.macro(std.meta.stringToEnum(Callable, w.text).?, words, i + 1);
            } else {
                try self.plainWord(w);
                i += 1;
            }
        }
    }

    /// Arguments in one font; delimiters stay roman.
    fn styled(self: *Parser, font: Font, args: []const Word, prefix: []const u8) Allocator.Error!void {
        for (args) |arg| {
            if (isOpening(arg) or isClosing(arg)) {
                try self.plainWord(arg);
                continue;
            }
            const t = try self.clean(arg.text);
            if (prefix.len > 0) {
                const joined = try std.mem.concat(self.a, u8, &.{ prefix, t });
                try self.emit(joined, font, false, false);
            } else try self.emit(t, font, false, false);
        }
    }

    fn enclosed(self: *Parser, open: []const u8, close: []const u8, words: []const Word, start: usize) Allocator.Error!usize {
        var end = words.len;
        while (end > start and isClosing(words[end - 1])) end -= 1;
        try self.emit(open, .roman, false, true);
        try self.parse(words[start..end]);
        try self.emit(close, .roman, true, false);
        for (words[end..]) |d| try self.plainWord(d);
        return words.len;
    }

    fn joinWords(self: *Parser, words: []const Word) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (words, 0..) |w, i| {
            if (i > 0) try out.append(self.a, ' ');
            try out.appendSlice(self.a, try self.clean(w.text));
        }
        return out.items;
    }

    /// Text of the arguments of a text macro such as `.At` or `.Bx`.
    fn argText(self: *Parser, args: []const Word) Allocator.Error![]const u8 {
        return self.joinWords(args);
    }

    fn macro(self: *Parser, m: Callable, words: []const Word, start: usize) Allocator.Error!usize {
        const end = argsEnd(words, start);
        const args = words[start..end];
        switch (m) {
            // Fonts.
            .Ad, .Em, .Pa, .Va, .Vt, .Fa, .Ft, .Ot => {
                if (m == .Fa and self.in_fo) {
                    if (!self.fo_first) try self.emit(",", .roman, true, false);
                    self.fo_first = false;
                }
                try self.styled(Font.i, args, "");
            },
            .Ar => if (args.len == 0) try self.emit("file ...", Font.i, false, false) else try self.styled(Font.i, args, ""),
            .Cm, .Ic, .Sy, .Fd, .Cd => try self.styled(Font.b, args, ""),
            .Fl => {
                if (args.len == 0) {
                    // `.Fl Fl long` is "--long": a bare flag sticks to the next one.
                    const next_is_fl = end < words.len and std.mem.eql(u8, words[end].text, "Fl");
                    try self.emit("-", Font.b, false, next_is_fl);
                } else try self.styled(Font.b, args, "-");
            },
            .Nm => {
                if (args.len > 0) {
                    if (self.nm.len == 0) self.nm = try self.joinWords(args);
                    try self.styled(Font.b, args, "");
                } else try self.emit(self.nm, Font.b, false, false);
            },
            .Li => try self.styled(Font.cw, args, ""),
            .Ql => {
                try self.emit("\u{2018}", .roman, false, true);
                try self.styled(Font.cw, args, "");
                try self.emit("\u{2019}", .roman, true, false);
            },
            .Ev, .Er, .Dv, .Ms, .Tn, .An, .Sx, .No => try self.styled(.roman, args, ""),
            .Ok, .Fr, .En, .Es, .Eo, .Ec, .Ud => {},

            // Spacing.
            .Ns => {
                self.space = false;
                return start;
            },
            .Pf => {
                if (args.len > 0) {
                    try self.emit(try self.clean(args[0].text), .roman, false, true);
                    return start + 1;
                }
            },
            .Ap => {
                try self.emit("'", .roman, true, true);
                return start;
            },
            .Ta, .Xo, .Xc => return start,

            // Enclosures.
            .Aq => return self.enclosed("<", ">", words, start),
            .Bq => return self.enclosed("[", "]", words, start),
            .Brq => return self.enclosed("{", "}", words, start),
            .Dq => return self.enclosed("\u{201c}", "\u{201d}", words, start),
            .Op => return self.enclosed("[", "]", words, start),
            .Pq => return self.enclosed("(", ")", words, start),
            .Qq => return self.enclosed("\"", "\"", words, start),
            .Sq => return self.enclosed("\u{2018}", "\u{2019}", words, start),
            .Ao => {
                try self.emit("<", .roman, false, true);
                return start;
            },
            .Ac => {
                try self.emit(">", .roman, true, false);
                return start;
            },
            .Bo, .Oo => {
                try self.emit("[", .roman, false, true);
                return start;
            },
            .Bc, .Oc => {
                try self.emit("]", .roman, true, false);
                return start;
            },
            .Bro => {
                try self.emit("{", .roman, false, true);
                return start;
            },
            .Brc => {
                try self.emit("}", .roman, true, false);
                return start;
            },
            .Do => {
                try self.emit("\u{201c}", .roman, false, true);
                return start;
            },
            .Dc => {
                try self.emit("\u{201d}", .roman, true, false);
                return start;
            },
            .Po => {
                try self.emit("(", .roman, false, true);
                return start;
            },
            .Pc => {
                try self.emit(")", .roman, true, false);
                return start;
            },
            .Qo => {
                try self.emit("\"", .roman, false, true);
                return start;
            },
            .Qc => {
                try self.emit("\"", .roman, true, false);
                return start;
            },
            .So => {
                try self.emit("\u{2018}", .roman, false, true);
                return start;
            },
            .Sc => {
                try self.emit("\u{2019}", .roman, true, false);
                return start;
            },

            // Cross references, functions, includes.
            .Xr => {
                if (args.len >= 1) {
                    const name = try self.clean(args[0].text);
                    const text = if (args.len >= 2)
                        try std.fmt.allocPrint(self.a, "{s}({s})", .{ name, try self.clean(args[1].text) })
                    else
                        name;
                    try self.emit(text, .roman, false, false);
                    for (args[@min(args.len, 2)..]) |d| try self.plainWord(d);
                }
            },
            .Fn => {
                if (args.len > 0) {
                    try self.emit(try self.clean(args[0].text), Font.b, false, false);
                    try self.emit("(", .roman, true, true);
                    var first = true;
                    var tail = args.len;
                    while (tail > 1 and isClosing(args[tail - 1])) tail -= 1;
                    for (args[1..tail]) |p| {
                        if (!first) try self.emit(",", .roman, true, false);
                        first = false;
                        try self.emit(try self.clean(p.text), Font.i, false, false);
                    }
                    try self.emit(")", .roman, true, false);
                    for (args[tail..]) |d| try self.plainWord(d);
                }
            },
            .Fo => {
                if (args.len > 0) {
                    try self.emit(try self.clean(args[0].text), Font.b, false, false);
                    try self.emit("(", .roman, true, true);
                    self.in_fo = true;
                    self.fo_first = true;
                }
            },
            .Fc => {
                self.in_fo = false;
                try self.emit(")", .roman, true, false);
                return start;
            },
            .In => {
                if (args.len > 0) {
                    const f = try self.clean(args[0].text);
                    const text = if (self.synopsis)
                        try std.fmt.allocPrint(self.a, "#include <{s}>", .{f})
                    else
                        try std.fmt.allocPrint(self.a, "<{s}>", .{f});
                    try self.emit(text, if (self.synopsis) Font.b else Font.cw, false, false);
                    for (args[1..]) |d| try self.plainWord(d);
                }
            },

            // Links.
            .Lk, .Mt => {
                if (args.len > 0) {
                    const url = try self.clean(args[0].text);
                    const link = try self.node(.link);
                    link.literal = if (m == .Mt) try std.fmt.allocPrint(self.a, "mailto:{s}", .{url}) else try self.a.dupe(u8, url);
                    if (self.space) try self.addRun(self.target, " ", .roman);
                    self.target.appendChild(link);
                    const saved = self.target;
                    self.target = link;
                    self.space = false;
                    var label_end = args.len;
                    while (label_end > 1 and isClosing(args[label_end - 1])) label_end -= 1;
                    if (label_end > 1) {
                        try self.parse(args[1..label_end]);
                    } else try self.addRun(link, url, .roman);
                    self.target = saved;
                    self.space = true;
                    for (args[label_end..]) |d| try self.plainWord(d);
                }
            },

            // Names of systems and standards.
            .At => try self.emit(atName(args), .roman, false, false),
            .Bx => try self.systemName("BSD", args),
            .Bsx => try self.systemName("BSD/OS", args),
            .Ox => try self.systemName("OpenBSD", args),
            .Fx => try self.systemName("FreeBSD", args),
            .Nx => try self.systemName("NetBSD", args),
            .Dx => try self.systemName("DragonFly", args),
            .Ux => try self.emit("UNIX", .roman, false, false),
            .St => {
                if (args.len > 0) try self.emit(standardName(args[0].text), .roman, false, false);
            },
            .Lb => {
                if (args.len > 0) try self.emit(libraryName(args[0].text), .roman, false, false);
            },
        }
        return end;
    }

    fn systemName(self: *Parser, name: []const u8, args: []const Word) Allocator.Error!void {
        // `.Bx 4.3` is "4.3BSD"; `.Ox 5.0` is "OpenBSD 5.0".
        if (args.len > 0 and std.mem.eql(u8, name, "BSD") and !std.mem.startsWith(u8, args[0].text, "-")) {
            const v = try self.clean(args[0].text);
            try self.emit(try std.fmt.allocPrint(self.a, "{s}BSD", .{v}), .roman, false, false);
            for (args[1..]) |d| try self.plainWord(d);
            return;
        }
        try self.emit(name, .roman, false, false);
        for (args) |x| if (!std.mem.startsWith(u8, x.text, "-")) try self.plainWord(x);
    }

    // ---- block macros ---------------------------------------------------------

    fn heading(self: *Parser, level: u8, args: []const Word) Allocator.Error!void {
        try self.closeAllLists();
        self.endPara();
        self.cur = self.root;
        const h = try self.node(.heading);
        h.level = level;
        self.root.appendChild(h);
        const text = try self.joinWords(args);
        try self.addRun(h, text, .roman);
        if (level == 2) {
            self.synopsis = std.ascii.eqlIgnoreCase(text, "SYNOPSIS");
        }
    }

    fn closeAllLists(self: *Parser) Allocator.Error!void {
        while (self.depth > 0) self.popList();
        self.bd_literal = false;
        try self.flushCode();
    }

    fn popList(self: *Parser) void {
        if (self.depth == 0) return;
        self.depth -= 1;
        self.cur = self.stack[self.depth].parent;
        self.endPara();
    }

    fn startList(self: *Parser, args: []const Word) Allocator.Error!void {
        self.endPara();
        if (self.depth >= max_levels) return;
        var kind: ListKind = .tag;
        for (args) |w| {
            if (std.mem.eql(u8, w.text, "-bullet") or std.mem.eql(u8, w.text, "-dash") or std.mem.eql(u8, w.text, "-hyphen") or std.mem.eql(u8, w.text, "-item")) kind = .bullet;
            if (std.mem.eql(u8, w.text, "-enum")) kind = .enumerated;
            if (std.mem.eql(u8, w.text, "-column")) kind = .column;
        }
        const list = switch (kind) {
            .tag => blk: {
                const d = try self.node(.deflist);
                d.list.tight = false;
                break :blk d;
            },
            .bullet, .enumerated => blk: {
                const l = try self.node(.list);
                l.list = if (kind == .bullet)
                    .{ .kind = .bullet, .tight = true, .bullet_char = '*' }
                else
                    .{ .kind = .ordered, .tight = true, .start = 1, .delimiter = '.' };
                break :blk l;
            },
            .column => try self.node(.table),
        };
        self.cur.appendChild(list);
        self.stack[self.depth] = .{ .kind = kind, .list = list, .parent = self.cur };
        self.depth += 1;
    }

    fn item(self: *Parser, args: []const Word) Allocator.Error!void {
        self.endPara();
        if (self.depth == 0) return;
        const ctx = &self.stack[self.depth - 1];
        self.space = false;
        switch (ctx.kind) {
            .tag => {
                const term = try self.node(.deflist_term);
                const def = try self.node(.deflist_def);
                ctx.list.appendChild(term);
                ctx.list.appendChild(def);
                self.cur = def;
                const saved = self.target;
                self.target = term;
                try self.parse(args);
                self.target = saved;
            },
            .bullet, .enumerated => {
                const it = try self.node(.item);
                ctx.list.appendChild(it);
                self.cur = it;
                if (args.len > 0) {
                    self.target = try self.paragraph();
                    try self.parse(args);
                }
            },
            .column => {
                const row = try self.node(.table_row);
                ctx.list.appendChild(row);
                var start: usize = 0;
                var i: usize = 0;
                while (i <= args.len) : (i += 1) {
                    if (i < args.len and !(std.mem.eql(u8, args[i].text, "Ta") and !args[i].quoted)) continue;
                    const cell = try self.node(.table_cell);
                    row.appendChild(cell);
                    const saved = self.target;
                    self.target = cell;
                    self.space = false;
                    try self.parse(args[start..i]);
                    self.target = saved;
                    start = i + 1;
                }
            },
        }
        ctx.item_open = true;
        self.space = false;
    }

    fn flushCode(self: *Parser) Allocator.Error!void {
        if (self.code.items.len == 0) return;
        const b = try self.node(.code_block);
        b.literal = try self.a.dupe(u8, self.code.items);
        self.cur.appendChild(b);
        self.code.clearRetainingCapacity();
    }

    /// Plain text of macro words (for displays that keep layout).
    fn plainOf(self: *Parser, words: []const Word) Allocator.Error![]const u8 {
        const tmp = try self.node(.paragraph);
        const saved_target = self.target;
        const saved_space = self.space;
        self.target = tmp;
        self.space = false;
        try self.parse(words);
        self.target = saved_target;
        self.space = saved_space;
        var out: std.ArrayList(u8) = .empty;
        try flatten(self.a, tmp, &out);
        return out.items;
    }

    fn flatten(a: Allocator, n: *Node, out: *std.ArrayList(u8)) Allocator.Error!void {
        var c = n.first_child;
        while (c) |x| : (c = x.next) switch (x.kind) {
            .text, .code => try out.appendSlice(a, x.literal),
            .softbreak, .linebreak => try out.append(a, ' '),
            else => try flatten(a, x, out),
        };
    }

    fn textMacro(self: *Parser, words: []const Word, plural: []const u8, single_pre: []const u8, single_post: []const u8, multi_post: []const u8, call_style: bool) Allocator.Error!void {
        _ = plural;
        // `.Ex -std [name ...]` and `.Rv -std [name ...]`.
        var names: std.ArrayList([]const u8) = .empty;
        for (words) |w| {
            if (std.mem.startsWith(u8, w.text, "-")) continue;
            try names.append(self.a, try self.clean(w.text));
        }
        if (names.items.len == 0 and self.nm.len > 0) try names.append(self.a, self.nm);
        if (names.items.len == 0) return;
        const p = try self.paragraphIn();
        self.target = p;
        self.space = false;
        try self.emit(single_pre, .roman, false, false);
        for (names.items, 0..) |n, i| {
            if (i > 0) try self.emit(if (i + 1 == names.items.len) "and" else ",", .roman, i + 1 != names.items.len, false);
            const label = if (call_style) try std.fmt.allocPrint(self.a, "{s}()", .{n}) else n;
            try self.emit(label, Font.b, false, false);
        }
        try self.emit(if (names.items.len == 1) single_post else multi_post, .roman, false, false);
        self.space = false;
    }

    /// A fresh paragraph in the current container.
    fn paragraphIn(self: *Parser) Allocator.Error!*Node {
        self.endPara();
        return self.paragraph();
    }

    fn reference(self: *Parser) *Reference {
        return &self.rs.?;
    }

    fn refField(self: *Parser, field: []const u8, words: []const Word) Allocator.Error!void {
        if (self.rs == null) return;
        const text = try self.joinWords(words);
        const r = self.reference();
        if (std.mem.eql(u8, field, "A")) try r.authors.append(self.a, text);
        if (std.mem.eql(u8, field, "T")) r.title = text;
        if (std.mem.eql(u8, field, "B")) r.book = text;
        if (std.mem.eql(u8, field, "J")) r.journal = text;
        if (std.mem.eql(u8, field, "V")) r.volume = text;
        if (std.mem.eql(u8, field, "N")) r.number = text;
        if (std.mem.eql(u8, field, "P")) r.pages = text;
        if (std.mem.eql(u8, field, "I")) r.publisher = text;
        if (std.mem.eql(u8, field, "C")) r.city = text;
        if (std.mem.eql(u8, field, "D")) r.date = text;
        if (std.mem.eql(u8, field, "R")) r.report = text;
        if (std.mem.eql(u8, field, "Q")) r.institution = text;
        if (std.mem.eql(u8, field, "O")) r.optional = text;
        if (std.mem.eql(u8, field, "U")) r.url = text;
    }

    fn endReference(self: *Parser) Allocator.Error!void {
        const r = self.rs orelse return;
        self.rs = null;
        const p = try self.paragraphIn();
        self.target = p;
        var out: std.ArrayList(u8) = .empty;
        const n = r.authors.items.len;
        for (r.authors.items, 0..) |au, i| {
            if (i > 0) try out.appendSlice(self.a, if (i + 1 == n) (if (n > 2) ", and " else " and ") else ", ");
            try out.appendSlice(self.a, au);
        }
        const parts = [_][]const u8{ "", r.title, r.book, r.journal, r.report, r.institution, r.publisher, r.city, r.optional, r.url };
        var first = n == 0;
        if (n > 0) {
            try self.addRun(p, out.items, .roman);
        }
        for (parts) |part| {
            if (part.len == 0) continue;
            if (!first) try self.addRun(p, ", ", .roman);
            first = false;
            try self.addRun(p, part, if (part.ptr == r.title.ptr) Font.roman else Font.roman);
        }
        const tail = [_][]const u8{ r.volume, r.number, r.pages, r.date };
        for (tail) |part| {
            if (part.len == 0) continue;
            if (!first) try self.addRun(p, ", ", .roman);
            first = false;
            try self.addRun(p, part, .roman);
        }
        try self.addRun(p, ".", .roman);
        self.endPara();
        self.space = false;
    }

    const break_macros = [_]Callable{ .Nm, .Ft, .Fd, .In, .Vt, .Fn, .Fo, .Cd };

    fn breaksInSynopsis(w: Word) bool {
        const m = std.meta.stringToEnum(Callable, w.text) orelse return false;
        for (break_macros) |b| if (b == m) return true;
        return false;
    }

    /// One macro or text line, already split into words (and without the dot).
    fn lineWords(self: *Parser, words: []const Word) Allocator.Error!void {
        if (words.len == 0) return;
        const first = words[0];
        if (!first.quoted) {
            if (std.meta.stringToEnum(Block, first.text)) |b| return self.block(b, words[1..]);
        }
        if (isCallable(first)) {
            if (self.bd_literal) {
                const text = try self.plainOf(words);
                try self.code.appendSlice(self.a, text);
                try self.code.append(self.a, '\n');
                return;
            }
            if (self.target != self.cur and self.target.kind != .paragraph) self.target = try self.paragraph();
            if (self.target.kind != .paragraph) self.target = try self.paragraph();
            const p = try self.paragraph();
            self.target = p;
            try self.lineSep(self.synopsis and breaksInSynopsis(first));
            self.space = false;
            try self.parse(words);
            return;
        }
        // Unknown macro: ignored.
    }

    fn block(self: *Parser, b: Block, args: []const Word) Allocator.Error!void {
        switch (b) {
            .Dd, .Os, .Db, .Sm, .Bk, .Ek, .Hf, .Tg => {},
            .Dt => {
                try self.closeAllLists();
                self.endPara();
                const h = try self.node(.heading);
                h.level = 1;
                self.root.appendChild(h);
                const title = if (args.len > 0) try self.clean(args[0].text) else "";
                const section = if (args.len > 1) try self.clean(args[1].text) else "";
                try self.addRun(h, try std.fmt.allocPrint(self.a, "{s}({s})", .{ title, section }), .roman);
            },
            .Sh => try self.heading(2, args),
            .Ss => try self.heading(3, args),
            .Pp, .Lp => self.endPara(),
            .Nd => {
                const p = try self.paragraph();
                self.target = p;
                self.space = true;
                try self.emit("\u{2014}", .roman, false, false);
                try self.parse(args);
            },
            .Bl => try self.startList(args),
            .El => self.popList(),
            .It => try self.item(args),
            .Bd => {
                self.endPara();
                for (args) |w| {
                    if (std.mem.eql(u8, w.text, "-literal") or std.mem.eql(u8, w.text, "-unfilled")) self.bd_literal = true;
                }
            },
            .Ed => {
                self.bd_literal = false;
                try self.flushCode();
            },
            .Dl, .D1 => {
                self.endPara();
                const text = try self.plainOf(args);
                try self.code.appendSlice(self.a, text);
                try self.code.append(self.a, '\n');
                try self.flushCode();
            },
            .Bf => {
                for (args) |w| {
                    if (std.mem.eql(u8, w.text, "-emphasis") or std.mem.eql(u8, w.text, "Em")) self.base_font = Font.i;
                    if (std.mem.eql(u8, w.text, "-symbolic") or std.mem.eql(u8, w.text, "Sy")) self.base_font = Font.b;
                    if (std.mem.eql(u8, w.text, "-literal") or std.mem.eql(u8, w.text, "Li")) self.base_font = Font.cw;
                }
            },
            .Ef => self.base_font = .roman,
            .Ex => try self.textMacro(args, "", "The ", " utility exits 0 on success, and >0 if an error occurs.", " utilities exit 0 on success, and >0 if an error occurs.", false),
            .Rv => try self.textMacro(args, "", "The ", " function returns the value 0 if successful; otherwise the value -1 is returned and the global variable errno is set to indicate the error.", " functions return the value 0 if successful; otherwise the value -1 is returned and the global variable errno is set to indicate the error.", true),
            .Rs => self.rs = .{},
            .Re => try self.endReference(),
            .@"%A" => try self.refField("A", args),
            .@"%B" => try self.refField("B", args),
            .@"%C" => try self.refField("C", args),
            .@"%D" => try self.refField("D", args),
            .@"%I" => try self.refField("I", args),
            .@"%J" => try self.refField("J", args),
            .@"%N" => try self.refField("N", args),
            .@"%O" => try self.refField("O", args),
            .@"%P" => try self.refField("P", args),
            .@"%Q" => try self.refField("Q", args),
            .@"%R" => try self.refField("R", args),
            .@"%T" => try self.refField("T", args),
            .@"%U" => try self.refField("U", args),
            .@"%V" => try self.refField("V", args),
        }
    }

    fn textLine(self: *Parser, l: []const u8) Allocator.Error!void {
        if (self.bd_literal) {
            try self.code.appendSlice(self.a, try escape.plain(self.a, &self.st, l));
            try self.code.append(self.a, '\n');
            return;
        }
        if (std.mem.trim(u8, l, " \t").len == 0) {
            self.endPara();
            return;
        }
        const p = try self.paragraph();
        self.target = p;
        try self.lineSep(false);
        self.space = false;
        const words = try splitWords(self.a, l);
        for (words) |w| try self.plainWord(w);
    }

    fn line(self: *Parser, raw: []const u8) Allocator.Error!void {
        self.line_no += 1;
        var l = raw;
        if (l.len > 0 and l[l.len - 1] == '\r') l = l[0 .. l.len - 1];
        const is_macro = l.len > 1 and (l[0] == '.' or l[0] == '\'') and l[1] != '\\' and !std.ascii.isWhitespace(l[1]);
        if (l.len > 1 and l[0] == '.' and std.mem.startsWith(u8, l[1..], "\\\"")) return; // comment
        if (std.mem.startsWith(u8, l, "\\\"")) return;

        var words: []const Word = &.{};
        if (is_macro) words = try splitWords(self.a, l[1..]);

        // `.Xo` ... `.Xc` joins several lines into one macro line.
        if (self.xo != null) {
            const w = if (is_macro) words else try splitWords(self.a, l);
            var depth_closed = false;
            if (is_macro and w.len > 0 and std.mem.eql(u8, w[0].text, "Xc")) {
                depth_closed = true;
                if (self.xo_depth > 1) self.xo_depth -= 1 else {
                    self.xo_depth = 0;
                }
            }
            if (!depth_closed or self.xo_depth > 0) {
                for (w) |x| {
                    if (!x.quoted and std.mem.eql(u8, x.text, "Xo")) self.xo_depth += 1;
                    try self.xo.?.append(self.a, x);
                }
                if (depth_closed) return;
                return;
            }
            const joined = self.xo.?.items;
            self.xo = null;
            try self.lineWords(joined);
            return;
        }
        if (is_macro) {
            for (words, 0..) |w, i| {
                if (!w.quoted and std.mem.eql(u8, w.text, "Xo")) {
                    var acc: std.ArrayList(Word) = .empty;
                    for (words, 0..) |x, j| if (j != i) try acc.append(self.a, x);
                    self.xo = acc;
                    self.xo_depth = 1;
                    return;
                }
            }
            try self.lineWords(words);
            return;
        }
        try self.textLine(l);
    }
};

/// Splits a macro line into words; a leading double quote starts a quoted word
/// (`""` inside is one quote).
fn splitWords(a: Allocator, s: []const u8) Allocator.Error![]Word {
    var out: std.ArrayList(Word) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
        if (i >= s.len) break;
        var buf: std.ArrayList(u8) = .empty;
        if (s[i] == '"') {
            i += 1;
            while (i < s.len) : (i += 1) {
                if (s[i] == '"') {
                    if (i + 1 < s.len and s[i + 1] == '"') {
                        try buf.append(a, '"');
                        i += 1;
                    } else {
                        i += 1;
                        break;
                    }
                } else try buf.append(a, s[i]);
            }
            try out.append(a, .{ .text = buf.items, .quoted = true });
        } else {
            while (i < s.len and s[i] != ' ' and s[i] != '\t') : (i += 1) try buf.append(a, s[i]);
            try out.append(a, .{ .text = buf.items });
        }
    }
    return out.items;
}

fn atName(args: []const Word) []const u8 {
    const table = [_][2][]const u8{
        .{ "v1", "Version 1 AT&T UNIX" },           .{ "v2", "Version 2 AT&T UNIX" },
        .{ "v3", "Version 3 AT&T UNIX" },           .{ "v4", "Version 4 AT&T UNIX" },
        .{ "v5", "Version 5 AT&T UNIX" },           .{ "v6", "Version 6 AT&T UNIX" },
        .{ "v7", "Version 7 AT&T UNIX" },           .{ "32v", "Version 32V AT&T UNIX" },
        .{ "III", "AT&T System III UNIX" },         .{ "V", "AT&T System V UNIX" },
        .{ "V.1", "AT&T System V Release 1 UNIX" }, .{ "V.2", "AT&T System V Release 2 UNIX" },
        .{ "V.3", "AT&T System V Release 3 UNIX" }, .{ "V.4", "AT&T System V Release 4 UNIX" },
    };
    if (args.len == 0) return "AT&T UNIX";
    for (table) |e| if (std.mem.eql(u8, e[0], args[0].text)) return e[1];
    return "AT&T UNIX";
}

fn standardName(arg: []const u8) []const u8 {
    const table = [_][2][]const u8{
        .{ "-p1003.1", "IEEE Std 1003.1 (\u{201c}POSIX.1\u{201d})" },
        .{ "-p1003.1-88", "IEEE Std 1003.1-1988 (\u{201c}POSIX.1\u{201d})" },
        .{ "-p1003.1-90", "ISO/IEC 9945-1:1990 (\u{201c}POSIX.1\u{201d})" },
        .{ "-p1003.1-96", "ISO/IEC 9945-1:1996 (\u{201c}POSIX.1\u{201d})" },
        .{ "-p1003.1-2001", "IEEE Std 1003.1-2001 (\u{201c}POSIX.1\u{201d})" },
        .{ "-p1003.1-2004", "IEEE Std 1003.1-2004 (\u{201c}POSIX.1\u{201d})" },
        .{ "-p1003.1-2008", "IEEE Std 1003.1-2008 (\u{201c}POSIX.1\u{201d})" },
        .{ "-p1003.1-2024", "IEEE Std 1003.1-2024 (\u{201c}POSIX.1\u{201d})" },
        .{ "-p1003.2", "IEEE Std 1003.2 (\u{201c}POSIX.2\u{201d})" },
        .{ "-isoC", "ISO/IEC 9899:1990 (\u{201c}ISO C90\u{201d})" },
        .{ "-isoC-90", "ISO/IEC 9899:1990 (\u{201c}ISO C90\u{201d})" },
        .{ "-isoC-99", "ISO/IEC 9899:1999 (\u{201c}ISO C99\u{201d})" },
        .{ "-isoC-2011", "ISO/IEC 9899:2011 (\u{201c}ISO C11\u{201d})" },
        .{ "-ansiC", "ANSI X3.159-1989 (\u{201c}ANSI C89\u{201d})" },
        .{ "-ansiC-89", "ANSI X3.159-1989 (\u{201c}ANSI C89\u{201d})" },
        .{ "-svid4", "System V Interface Definition, Fourth Edition (\u{201c}SVID4\u{201d})" },
        .{ "-xpg4", "X/Open Portability Guide Issue 4 (\u{201c}XPG4\u{201d})" },
        .{ "-xpg4.2", "X/Open Portability Guide Issue 4, Version 2 (\u{201c}XPG4.2\u{201d})" },
        .{ "-susv2", "Version 2 of the Single UNIX Specification (\u{201c}SUSv2\u{201d})" },
        .{ "-susv3", "Version 3 of the Single UNIX Specification (\u{201c}SUSv3\u{201d})" },
        .{ "-susv4", "Version 4 of the Single UNIX Specification (\u{201c}SUSv4\u{201d})" },
    };
    for (table) |e| if (std.mem.eql(u8, e[0], arg)) return e[1];
    return if (std.mem.startsWith(u8, arg, "-")) arg[1..] else arg;
}

fn libraryName(arg: []const u8) []const u8 {
    const table = [_][2][]const u8{
        .{ "libc", "Standard C Library (libc, -lc)" },
        .{ "libm", "Math Library (libm, -lm)" },
        .{ "libutil", "System Utilities Library (libutil, -lutil)" },
        .{ "libpthread", "POSIX Threads Library (libpthread, -lpthread)" },
        .{ "librt", "Real-time Library (librt, -lrt)" },
        .{ "libcrypt", "Crypt Library (libcrypt, -lcrypt)" },
        .{ "libdl", "Dynamic Linker Library (libdl, -ldl)" },
        .{ "libz", "Compression Library (libz, -lz)" },
    };
    for (table) |e| if (std.mem.eql(u8, e[0], arg)) return e[1];
    return arg;
}

/// Parses an mdoc(7) page. The tree is owned by the returned document.
pub fn parse(gpa: Allocator, source: []const u8) Allocator.Error!md.Document {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const root = try a.create(Node);
    root.* = .{ .kind = .document, .line = 1 };
    root.build.open = false;

    var p: Parser = .{ .a = a, .root = root, .cur = root, .target = root };
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |l| try p.line(l);
    try p.endReference();
    try p.flushCode();
    return .{ .arena = arena, .root = root };
}

test "splitWords keeps quotes apart" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const w = try splitWords(arena_state.allocator(), "Fn open \"const char *p\" Ar x");
    try std.testing.expectEqual(@as(usize, 5), w.len);
    try std.testing.expect(w[2].quoted);
    try std.testing.expectEqualStrings("const char *p", w[2].text);
}

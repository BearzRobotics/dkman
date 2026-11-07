//! Reader for man(7) pages. Builds an md-zig tree:
//!
//!   .TH            heading level 1        .SH / .SS     heading level 2 / 3
//!   .PP .P .LP     paragraph              .TP / .IP     definition list or bullet list
//!   .RS / .RE      block quote            .nf .fi .EX   code block
//!   .B .I .BR ...  strong / emphasis      .UR .MT       links
//!
//! What roff can express and the tree cannot (exact indents, tabs, tbl layout,
//! macros defined with .de) is approximated or dropped; see docs/architecture.md.

const std = @import("std");
const md = @import("md");
const Allocator = std.mem.Allocator;
const Node = md.Node;
const escape = @import("escape.zig");
const Font = escape.Font;

/// Deepest `.RS` nesting followed; more is ignored.
const max_levels = 16;

const Parser = struct {
    a: Allocator,
    root: *Node,
    st: escape.State = .{},

    /// Where blocks of the current indentation level go.
    container: *Node,
    /// Where paragraphs go now: `container`, or a definition inside it.
    cur: *Node,
    levels: [max_levels]*Node = undefined,
    depth: usize = 0,

    para: ?*Node = null,
    open_dl: ?*Node = null,
    open_list: ?*Node = null,
    /// The next text line (or font macro) fills this node instead of a paragraph.
    pending_term: ?*Node = null,
    pending_heading: ?*Node = null,
    /// Link opened by `.UR`/`.MT` that receives inlines until `.UE`/`.ME`.
    link: ?*Node = null,
    one_shot: ?Font = null,

    nofill: bool = false,
    code: std.ArrayList(u8) = .empty,
    in_tbl: bool = false,
    tbl_format_done: bool = false,
    skip_until_dotdot: bool = false,
    skip_depth: usize = 0,
    last_cond: bool = false,
    continued: bool = false,
    line_no: u32 = 0,

    fn node(self: *Parser, kind: md.Kind) Allocator.Error!*Node {
        const n = try self.a.create(Node);
        n.* = .{ .kind = kind, .line = self.line_no };
        n.build.open = false;
        return n;
    }

    // ---- blocks ------------------------------------------------------------

    fn endPara(self: *Parser) void {
        self.para = null;
        self.continued = false;
    }

    /// Back to the level's container: no open definition or list.
    fn endGroup(self: *Parser) void {
        self.endPara();
        self.open_dl = null;
        self.open_list = null;
        self.pending_term = null;
        self.cur = self.container;
        self.link = null;
    }

    fn flushCode(self: *Parser) Allocator.Error!void {
        if (self.code.items.len == 0) return;
        const b = try self.node(.code_block);
        b.literal = try self.a.dupe(u8, self.code.items);
        self.cur.appendChild(b);
        self.code.clearRetainingCapacity();
    }

    /// Where inline content goes now.
    fn sink(self: *Parser) Allocator.Error!*Node {
        if (self.pending_heading) |h| return h;
        if (self.pending_term) |t| return t;
        if (self.link) |l| return l;
        if (self.para) |p| return p;
        const p = try self.node(.paragraph);
        self.cur.appendChild(p);
        self.para = p;
        return p;
    }

    /// After the text for a pending heading or term: go on with normal flow.
    fn contentDone(self: *Parser) void {
        if (self.pending_heading != null) self.pending_heading = null;
        if (self.pending_term != null) self.pending_term = null;
    }

    fn heading(self: *Parser, level: u8, args: []const []const u8) Allocator.Error!void {
        self.endGroup();
        self.container = self.root;
        self.depth = 0;
        self.cur = self.root;
        const h = try self.node(.heading);
        h.level = level;
        self.root.appendChild(h);
        if (args.len == 0) {
            self.pending_heading = h;
            return;
        }
        const joined = try std.mem.join(self.a, " ", args);
        try self.addText(h, joined, true);
    }

    /// Starts a definition list entry whose term is `tag` (or filled by the
    /// next line when null).
    fn startTagged(self: *Parser, tag: ?[]const u8) Allocator.Error!void {
        self.endPara();
        self.open_list = null;
        const dl = self.open_dl orelse blk: {
            const d = try self.node(.deflist);
            d.list.tight = false;
            self.container.appendChild(d);
            self.open_dl = d;
            break :blk d;
        };
        const term = try self.node(.deflist_term);
        const def = try self.node(.deflist_def);
        dl.appendChild(term);
        dl.appendChild(def);
        self.cur = def;
        if (tag) |t| {
            try self.addText(term, t, true);
        } else self.pending_term = term;
    }

    fn startBullet(self: *Parser) Allocator.Error!void {
        self.endPara();
        self.open_dl = null;
        const list = self.open_list orelse blk: {
            const l = try self.node(.list);
            l.list = .{ .kind = .bullet, .tight = true, .bullet_char = '*' };
            self.container.appendChild(l);
            self.open_list = l;
            break :blk l;
        };
        const item = try self.node(.item);
        list.appendChild(item);
        self.cur = item;
    }

    fn isBullet(tag: []const u8) bool {
        return std.mem.eql(u8, tag, "\\(bu") or std.mem.eql(u8, tag, "\\[bu]") or std.mem.eql(u8, tag, "\u{2022}") or
            std.mem.eql(u8, tag, "*") or std.mem.eql(u8, tag, "-") or std.mem.eql(u8, tag, "\\-") or std.mem.eql(u8, tag, "o");
    }

    fn pushQuote(self: *Parser) Allocator.Error!void {
        self.endGroup();
        if (self.depth >= max_levels) return;
        self.levels[self.depth] = self.container;
        self.depth += 1;
        const q = try self.node(.block_quote);
        self.container.appendChild(q);
        self.container = q;
        self.cur = q;
    }

    fn popQuote(self: *Parser) void {
        self.endGroup();
        if (self.depth == 0) return;
        self.depth -= 1;
        self.container = self.levels[self.depth];
        self.cur = self.container;
    }

    // ---- inlines -----------------------------------------------------------

    /// Appends `s` (with escapes) to `parent`. `fresh` ignores and resets the
    /// font state: used by macros that set their own font.
    fn addText(self: *Parser, parent: *Node, s: []const u8, fresh: bool) Allocator.Error!void {
        const saved = self.st;
        if (fresh) {
            self.st.font = .roman;
            self.st.prev = .roman;
        }
        const r = try escape.segments(self.a, &self.st, s);
        if (fresh) {
            self.st.font = saved.font;
            self.st.prev = saved.prev;
        }
        for (r.segments) |seg| try self.addRun(parent, seg.text, seg.font);
        self.continued = r.continued;
    }

    fn addRun(self: *Parser, parent: *Node, text: []const u8, font: Font) Allocator.Error!void {
        var inner = try self.node(if (font.mono) .code else .text);
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
    }

    /// A line break between two input lines of one paragraph.
    fn lineSep(self: *Parser, parent: *Node) Allocator.Error!void {
        if (self.continued) {
            self.continued = false;
            return;
        }
        if (parent.last_child) |last| {
            if (last.kind != .softbreak and last.kind != .linebreak) parent.appendChild(try self.node(.softbreak));
        }
    }

    fn textLine(self: *Parser, l: []const u8) Allocator.Error!void {
        if (std.mem.trim(u8, l, " \t").len == 0) {
            // A blank line ends the paragraph (roff treats it like .sp).
            self.endPara();
            return;
        }
        const target = try self.sink();
        const was_term = self.pending_term != null or self.pending_heading != null;
        try self.lineSep(target);
        if (self.one_shot) |f| {
            self.one_shot = null;
            self.st.setFont(f);
            try self.addText(target, l, false);
            self.st.setFont(.roman);
        } else try self.addText(target, l, false);
        if (was_term) self.contentDone();
    }

    /// `.B`, `.I`, `.SM`: all arguments, one font, separated by spaces.
    fn singleFont(self: *Parser, font: Font, args: []const []const u8) Allocator.Error!void {
        if (args.len == 0) {
            self.one_shot = font;
            return;
        }
        const target = try self.sink();
        const was_term = self.pending_term != null or self.pending_heading != null;
        try self.lineSep(target);
        const joined = try std.mem.join(self.a, " ", args);
        self.st.setFont(font);
        try self.addText(target, joined, false);
        self.st.font = .roman;
        self.st.prev = .roman;
        if (was_term) self.contentDone();
    }

    /// `.BR`, `.IB`, ...: arguments alternate between two fonts, no spaces.
    fn alternating(self: *Parser, f0: Font, f1: Font, args: []const []const u8) Allocator.Error!void {
        const target = try self.sink();
        const was_term = self.pending_term != null or self.pending_heading != null;
        try self.lineSep(target);
        for (args, 0..) |arg, idx| {
            self.st.setFont(if (idx % 2 == 0) f0 else f1);
            try self.addText(target, arg, false);
        }
        self.st.font = .roman;
        self.st.prev = .roman;
        if (was_term) self.contentDone();
    }

    // ---- requests ----------------------------------------------------------

    const Request = enum {
        TH,
        SH,
        SS,
        PP,
        P,
        LP,
        HP,
        TP,
        TQ,
        IP,
        RS,
        RE,
        B,
        I,
        SM,
        SB,
        BR,
        BI,
        IB,
        RB,
        IR,
        RI,
        br,
        sp,
        nf,
        fi,
        EX,
        EE,
        TS,
        TE,
        UR,
        UE,
        MT,
        ME,
        SY,
        OP,
        YS,
        ds,
        de,
        am,
        ig,
        @"if",
        ie,
        el,
        so,
        nr,
        ft,
        ce,
        ta,
        ne,
        ad,
        na,
        hy,
        nh,
        in,
        ti,
        ll,
        lt,
        pl,
        po,
        ps,
        vs,
        ss,
        fc,
        cc,
        c2,
        mk,
        rt,
        bp,
        pn,
        nx,
        rm,
        rn,
    };

    fn request(self: *Parser, l: []const u8) Allocator.Error!void {
        const body = std.mem.trimStart(u8, l, " \t");
        if (body.len == 0) return;
        if (std.mem.startsWith(u8, body, "\\\"")) return; // comment
        const name_end = std.mem.indexOfAny(u8, body, " \t") orelse body.len;
        const name = body[0..name_end];
        const rest = std.mem.trimStart(u8, body[name_end..], " \t");

        const req = std.meta.stringToEnum(Request, name) orelse return; // unknown requests are ignored
        const args = try splitArgs(self.a, rest);

        if (self.nofill and self.in_tbl == false) {
            switch (req) {
                .fi, .EE, .RE, .TS => {},
                .B, .I, .SM, .SB, .BR, .BI, .IB, .RB, .IR, .RI => {
                    // Font macros inside a code block: keep the text.
                    for (args) |arg| try self.code.appendSlice(self.a, try escape.plain(self.a, &self.st, arg));
                    try self.code.append(self.a, '\n');
                    return;
                },
                .sp => {
                    try self.code.append(self.a, '\n');
                    return;
                },
                .br => return,
                else => {},
            }
        }

        switch (req) {
            .TH => {
                self.endGroup();
                const h = try self.node(.heading);
                h.level = 1;
                self.root.appendChild(h);
                const title = if (args.len > 0) args[0] else "";
                const section = if (args.len > 1) args[1] else "";
                const text = try std.fmt.allocPrint(self.a, "{s}({s})", .{ title, section });
                try self.addRun(h, text, .roman);
            },
            .SH => try self.heading(2, args),
            .SS => try self.heading(3, args),
            .PP, .P, .LP, .HP => self.endGroup(),
            .TP, .TQ => try self.startTagged(null),
            .IP => {
                if (args.len == 0) {
                    // Plain indented paragraph inside the current group.
                    self.endPara();
                } else if (isBullet(args[0])) {
                    try self.startBullet();
                } else try self.startTagged(args[0]);
            },
            .RS => try self.pushQuote(),
            .RE => self.popQuote(),
            .B => try self.singleFont(Font.b, args),
            .I => try self.singleFont(Font.i, args),
            .SM => try self.singleFont(Font.roman, args),
            .SB => try self.singleFont(Font.b, args),
            .BR => try self.alternating(Font.b, Font.roman, args),
            .BI => try self.alternating(Font.b, Font.i, args),
            .IB => try self.alternating(Font.i, Font.b, args),
            .RB => try self.alternating(Font.roman, Font.b, args),
            .IR => try self.alternating(Font.i, Font.roman, args),
            .RI => try self.alternating(Font.roman, Font.i, args),
            .br => {
                if (self.para) |p| {
                    if (p.last_child != null) p.appendChild(try self.node(.linebreak));
                }
            },
            .sp, .ne, .bp => self.endPara(),
            .nf, .EX => {
                self.endPara();
                self.nofill = true;
            },
            .fi, .EE => {
                self.nofill = false;
                try self.flushCode();
            },
            .TS => {
                self.endPara();
                self.nofill = true;
                self.in_tbl = true;
                self.tbl_format_done = false;
            },
            .TE => {
                self.nofill = false;
                self.in_tbl = false;
                try self.flushCode();
            },
            .UR, .MT => {
                const target = try self.sink();
                try self.lineSep(target);
                const lnk = try self.node(.link);
                const dest = if (args.len > 0) args[0] else "";
                lnk.literal = if (req == .MT) try std.fmt.allocPrint(self.a, "mailto:{s}", .{dest}) else try self.a.dupe(u8, dest);
                target.appendChild(lnk);
                self.link = lnk;
            },
            .UE, .ME => {
                if (self.link) |lnk| {
                    // A link without text shows its address.
                    if (lnk.first_child == null) try self.addRun(lnk, lnk.literal, .roman);
                    self.link = null;
                    // Trailing punctuation is the first argument.
                    if (args.len > 0) try self.addText(try self.sink(), args[0], false);
                }
            },
            .SY => {
                self.endPara();
                const target = try self.sink();
                if (args.len > 0) try self.addRun(target, args[0], Font.b);
            },
            .OP => {
                const target = try self.sink();
                try self.addRun(target, " [", .roman);
                if (args.len > 0) try self.addRun(target, args[0], Font.b);
                if (args.len > 1) {
                    try self.addRun(target, " ", .roman);
                    try self.addRun(target, args[1], Font.i);
                }
                try self.addRun(target, "]", .roman);
            },
            .YS => self.endPara(),
            .ds => {
                if (args.len >= 1) {
                    const value = if (args.len > 1) try std.mem.join(self.a, " ", args[1..]) else "";
                    try self.st.strings.put(self.a, args[0], value);
                }
            },
            .de, .am, .ig => self.skip_until_dotdot = true,
            .@"if", .ie => try self.conditional(rest, req == .ie),
            .el => try self.elseBranch(rest),
            else => {}, // layout requests with no counterpart in the tree
        }
    }

    /// `.if COND body` and `.ie COND body`: only the terminal conditions `n`,
    /// `t` (and their negations) are evaluated; others count as false.
    fn conditional(self: *Parser, rest: []const u8, is_ie: bool) Allocator.Error!void {
        var s = rest;
        var negate = false;
        if (s.len > 0 and s[0] == '!') {
            negate = true;
            s = s[1..];
        }
        const end = std.mem.indexOfAny(u8, s, " \t") orelse s.len;
        const cond = s[0..end];
        var truth = std.mem.eql(u8, cond, "n");
        if (negate) truth = !truth;
        if (is_ie) self.last_cond = truth;
        try self.branch(truth, std.mem.trimStart(u8, s[end..], " \t"));
    }

    fn elseBranch(self: *Parser, rest: []const u8) Allocator.Error!void {
        try self.branch(!self.last_cond, rest);
    }

    /// Runs the body of a conditional if `truth`; skips a `\{ ... \}` block otherwise.
    fn branch(self: *Parser, truth: bool, body: []const u8) Allocator.Error!void {
        if (std.mem.startsWith(u8, body, "\\{")) {
            const inner = std.mem.trimStart(u8, body[2..], " \t");
            if (truth) {
                if (inner.len > 0) try self.line(inner);
            } else {
                self.skip_depth = 1 + braceDelta(inner);
            }
        } else if (truth and body.len > 0) {
            try self.line(body);
        }
    }

    /// Opening braces minus closing braces on a line.
    fn braceDelta(l: []const u8) usize {
        // Only used when skipping; a negative result cannot be represented and
        // is clamped by the caller (skip_depth stops at 0).
        var opens: usize = 0;
        var closes: usize = 0;
        var i: usize = 0;
        while (i + 1 < l.len) : (i += 1) {
            if (l[i] == '\\' and l[i + 1] == '{') opens += 1;
            if (l[i] == '\\' and l[i + 1] == '}') closes += 1;
        }
        return if (opens >= closes) opens - closes else 0;
    }

    // ---- lines -------------------------------------------------------------

    fn line(self: *Parser, raw: []const u8) Allocator.Error!void {
        self.line_no += 1;
        var l = raw;
        if (l.len > 0 and l[l.len - 1] == '\r') l = l[0 .. l.len - 1];

        if (self.skip_until_dotdot) {
            if (std.mem.startsWith(u8, l, "..")) self.skip_until_dotdot = false;
            return;
        }
        if (self.skip_depth > 0) {
            var i: usize = 0;
            while (i + 1 < l.len) : (i += 1) {
                if (l[i] == '\\' and l[i + 1] == '{') self.skip_depth += 1;
                if (l[i] == '\\' and l[i + 1] == '}') {
                    self.skip_depth -= 1;
                    if (self.skip_depth == 0) break;
                }
            }
            return;
        }
        // The end of a taken conditional block.
        if (std.mem.endsWith(u8, l, "\\}")) l = l[0 .. l.len - 2];
        if (std.mem.eql(u8, std.mem.trim(u8, l, " \t"), ".")) return;

        if (self.in_tbl) return self.tblLine(l);
        if (l.len > 0 and (l[0] == '.' or l[0] == '\'')) {
            const is_end = std.mem.startsWith(u8, l[1..], "fi") or std.mem.startsWith(u8, l[1..], "EE");
            if (!self.nofill or is_end or isRequestInNofill(l)) return self.request(l[1..]);
        }
        if (self.nofill) {
            try self.code.appendSlice(self.a, try escape.plain(self.a, &self.st, l));
            try self.code.append(self.a, '\n');
            return;
        }
        try self.textLine(l);
    }

    fn isRequestInNofill(l: []const u8) bool {
        // Control lines stay requests inside .nf blocks (comments, fonts, .fi ...).
        return l.len > 1 and l[0] == '.' and !std.ascii.isWhitespace(l[1]);
    }

    /// Lines between `.TS` and `.TE`: a format section ending in a line that
    /// ends with `.`, then rows with tab-separated cells.
    fn tblLine(self: *Parser, l: []const u8) Allocator.Error!void {
        if (l.len > 0 and l[0] == '.' and (std.mem.startsWith(u8, l[1..], "TE"))) return self.request(l[1..]);
        if (!self.tbl_format_done) {
            if (std.mem.endsWith(u8, std.mem.trimEnd(u8, l, " \t"), ".")) self.tbl_format_done = true;
            return;
        }
        const t = std.mem.trim(u8, l, " \t");
        if (t.len == 0 or std.mem.eql(u8, t, "_") or std.mem.eql(u8, t, "=")) return;
        const plain_text = try escape.plain(self.a, &self.st, l);
        for (plain_text) |c| try self.code.append(self.a, if (c == '\t') ' ' else c);
        try self.code.append(self.a, '\n');
    }
};

/// Splits request arguments: blanks separate them, double quotes group (a
/// doubled quote inside is a literal quote).
fn splitArgs(a: Allocator, s: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
        if (i >= s.len) break;
        var arg: std.ArrayList(u8) = .empty;
        if (s[i] == '"') {
            i += 1;
            while (i < s.len) : (i += 1) {
                if (s[i] == '"') {
                    if (i + 1 < s.len and s[i + 1] == '"') {
                        try arg.append(a, '"');
                        i += 1;
                    } else {
                        i += 1;
                        break;
                    }
                } else try arg.append(a, s[i]);
            }
        } else {
            while (i < s.len and s[i] != ' ' and s[i] != '\t') : (i += 1) {
                // An escaped blank belongs to the argument.
                if (s[i] == '\\' and i + 1 < s.len and s[i + 1] == ' ') {
                    try arg.appendSlice(a, "\\ ");
                    i += 1;
                } else try arg.append(a, s[i]);
            }
        }
        try out.append(a, arg.items);
    }
    return out.items;
}

/// Parses a man(7) page. The tree is owned by the returned document.
pub fn parse(gpa: Allocator, source: []const u8) Allocator.Error!md.Document {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const root = try a.create(Node);
    root.* = .{ .kind = .document, .line = 1 };
    root.build.open = false;

    var p: Parser = .{ .a = a, .root = root, .container = root, .cur = root };
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |l| try p.line(l);
    try p.flushCode();
    return .{ .arena = arena, .root = root };
}

test "splitArgs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const r = try splitArgs(a, "ls 1 \"June 2026\" \"say \"\"hi\"\"\"  x\\ y");
    try std.testing.expectEqual(@as(usize, 5), r.len);
    try std.testing.expectEqualStrings("June 2026", r[2]);
    try std.testing.expectEqualStrings("say \"hi\"", r[3]);
    try std.testing.expectEqualStrings("x\\ y", r[4]);
}

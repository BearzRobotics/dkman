//! Shell wildcards for `-k --wildcard` and `-f --wildcard`. Regular
//! expressions come from the regex-zig package.

const std = @import("std");

/// Shell wildcard match of the whole `text`: `*`, `?` and `[set]` (ranges and
/// `!`/`^` negation), ignoring ASCII case.
pub fn glob(pattern: []const u8, text: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;
    var star_p: ?usize = null;
    var star_t: usize = 0;
    while (t < text.len) {
        if (p < pattern.len) {
            switch (pattern[p]) {
                '*' => {
                    star_p = p;
                    star_t = t;
                    p += 1;
                    continue;
                },
                '?' => {
                    p += 1;
                    t += 1;
                    continue;
                },
                '[' => if (globSet(pattern, p, text[t])) |next| {
                    p = next;
                    t += 1;
                    continue;
                } else |_| {},
                else => |c| if (std.ascii.toLower(c) == std.ascii.toLower(text[t])) {
                    p += 1;
                    t += 1;
                    continue;
                },
            }
        }
        // Mismatch: let the last `*` take one more character.
        const sp = star_p orelse return false;
        star_t += 1;
        t = star_t;
        p = sp + 1;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

/// Matches `c` against the set starting at `pattern[start] == '['`. Returns the
/// index after the set when it matches, `error.NoMatch` when it does not (a
/// set that is never closed is the literal `[`).
fn globSet(pattern: []const u8, start: usize, c: u8) error{NoMatch}!usize {
    var i = start + 1;
    var negate = false;
    if (i < pattern.len and (pattern[i] == '!' or pattern[i] == '^')) {
        negate = true;
        i += 1;
    }
    var matched = false;
    var first = true;
    while (i < pattern.len) {
        if (pattern[i] == ']' and !first) {
            return if (matched != negate) i + 1 else error.NoMatch;
        }
        first = false;
        const lo = pattern[i];
        var hi = lo;
        if (i + 2 < pattern.len and pattern[i + 1] == '-' and pattern[i + 2] != ']') {
            hi = pattern[i + 2];
            i += 2;
        }
        const lc = std.ascii.toLower(c);
        if ((lc >= std.ascii.toLower(lo) and lc <= std.ascii.toLower(hi)) or (c >= lo and c <= hi)) matched = true;
        i += 1;
    }
    // No closing bracket: `[` stands for itself.
    return if (c == '[') start + 1 else error.NoMatch;
}

test "glob" {
    const t = std.testing;
    try t.expect(glob("*", "anything"));
    try t.expect(glob("*", ""));
    try t.expect(glob("ls*", "lsblk"));
    try t.expect(!glob("ls*", "als"));
    try t.expect(glob("*sh", "bash"));
    try t.expect(glob("b?sh", "BASH"));
    try t.expect(!glob("b?sh", "bsh"));
    try t.expect(glob("[a-c]at", "cat"));
    try t.expect(!glob("[a-c]at", "dat"));
    try t.expect(glob("[!a-c]at", "dat"));
    try t.expect(glob("a*b*c", "aXXbYYc"));
    try t.expect(!glob("a*b*c", "aXXbYY"));
    try t.expect(glob("*a*", "xxaxx"));
    try t.expect(glob("[x", "[x"));
}

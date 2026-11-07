# gtroff-zig

Reads roff manual pages into an [md-zig](https://github.com/BearzRobotics/md-zig)
tree, so one renderer ([dkman](https://github.com/BearzRobotics/dkman)) can show
Markdown documents and man pages the same way. Zig 0.17.1, no other dependencies.

Status:

| Format | State |
|---|---|
| man(7) | Reads real pages: sections, tagged and bullet paragraphs, indents, code blocks, font macros, links, simple conditionals, `.ds` strings, tbl as plain rows |
| mdoc(7) | Not done |
| Full troff/groff (macros defined with `.de`, number registers, `\w`, diversions) | Not done and not planned: such requests are skipped |

```zig
const gtroff = @import("gtroff");

var doc = try gtroff.parseMan(gpa, source);   // an md.Document
defer doc.deinit();
try doc.writeText(gpa, writer, .{ .width = 80 }); // md-zig's terminal renderer
```

Add it to a project with `zig fetch --save https://github.com/BearzRobotics/gtroff-zig/releases/download/v0.1.0/gtroff-0.1.0.tar.gz`
and import the `gtroff` module.

**C interface (experimental, unstable):** `include/gtroff.h` and `zig build c-api`
(`libgtroff.a`, `libgtroff.so`); `zig build test` runs a C program against it.
It renders a man page held in memory to terminal text or HTML.

The result is an ordinary `md.Document`; HTML output or a GTK viewer work the
same as for Markdown. See `docs/architecture.md` for how roff maps to the tree
and what is lost, and `docs/decisions/` for the reasoning. Tests: `zig build test`.
License: MIT.

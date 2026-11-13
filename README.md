# dkman

A manual page tool in Zig, meant to replace man(1): finds pages in the traditional
directories (gzip, xz, zstd, bzip2 and lzma compressed too), answers `-f` (whatis) and
`-k` (apropos) from a cached index of the NAME lines, searches pages in a built-in
browser (`-b`: search box and preview), and shows them through a pager. Markdown documents
(`name.1.md`) are first-class pages, read with
[md-zig](https://github.com/BearzRobotics/md-zig).

Status: Markdown, plain and gzip pages work, and man(7) and mdoc(7) pages are
read with [gtroff-zig](https://github.com/BearzRobotics/gtroff-zig) (every man1,
man3, man5 and man8 page on the development machine rendered without a crash).
Content matches groff on sampled pages and most lines have the same indent;
layout is still approximate (text is not justified, tables are drawn as grids).

    zig build
    zig-out/bin/dkman -l README.md
    zig-out/bin/dkman 3 printf
    zig-out/bin/dkman -f printf
    zig-out/bin/dkman -b

See `docs/manpages/dkman.1.md` for the options, `docs/architecture.md` for the
layout and `docs/decisions/` for the reasoning. Zig 0.17.1. `test/tools/cli.sh` checks the command line. Dependencies (md-zig, gtroff-zig) are fetched
by `zig build` from their GitHub releases. License: MIT.

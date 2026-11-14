# dkman

A manual page tool in Zig, meant to replace man(1): finds pages in the traditional
directories (gzip, xz, zstd, bzip2 and lzma compressed too, all decoded in process), answers `-f` (whatis) and
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

Install (the program, its manual page as man(7) generated from `docs/manpages/dkman.1.md`, and bash, zsh and fish completions):

    zig build -Doptimize=ReleaseSafe --prefix /usr/local     # or ReleaseSmall: about 0.6 MB, static with -Dtarget=x86_64-linux-musl
    zig build -Doptimize=ReleaseSafe --prefix /usr/local -Dinstall-as-man   # also as man, whatis, apropos, manpath, mandb

The page index for `-f` and `-k` is built on first use (about a second) and cached
in `~/.cache/dkman/`. Page names in the completions come from it.

See `docs/manpages/dkman.1.md` for the options, `docs/architecture.md` for the
layout and `docs/decisions/` for the reasoning. Zig 0.17.1. `test/tools/cli.sh` checks the command line. Dependencies (md-zig, gtroff-zig, regex-zig) are fetched
by `zig build` from their GitHub releases. License: MIT.

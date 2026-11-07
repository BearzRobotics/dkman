# dkman

A manual page tool in Zig: finds pages in the traditional directories, searches
them with fzf, and shows them through a pager. Markdown documents
(`name.1.md`) are first-class pages, read with
[md-zig](https://github.com/BearzRobotics/md-zig).

Status: Markdown, plain and gzip pages work. Classic roff (man and mdoc) pages
are detected but not yet shown: they need
[gtroff-zig](https://github.com/BearzRobotics/gtroff-zig).

    zig build
    zig-out/bin/dkman -l README.md
    zig-out/bin/dkman 3 printf
    zig-out/bin/dkman -f

See `docs/manpages/dkman.1.md` for the options, `docs/architecture.md` for the
layout and `docs/decisions/` for the reasoning. Zig 0.17.1. The build expects
md-zig in `../md-zig` for now. License: MIT.

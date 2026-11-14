# 0002: Behaving like man(1)

Status: proposed by the assistant, approved in conversation by the maintainer
("Lets bring this up to spec"); the choices marked **review** went beyond what
was spelled out and need the maintainer's confirmation.

## Problem

dkman should be usable as the system `man`: scripts and habits call man(1)
with its options, pipe its output, and rely on its exit codes. Gaps found:
only gzip pages opened; `-f` meant "browse" (man: whatis); `-k` matched names
only; no `-s`, `-a`, `-M`, `-L`, `-V`; piped output contained Markdown markers;
`MANPATH` was never derived from `PATH`; locale directories were ignored.

## Decisions

1. **Compression is found by magic bytes**, not by suffix (`source.zig`).
   gzip, xz, zstd and LZMA-alone are decoded with `std.compress`; bzip2, which
   the standard library lacks, by `bzip2.zig` (about 300 lines, written from the
   bzip2 1.0.x format, with block and stream CRC checks). No external program
   is run. archive.zig (github.com/muhammad-fiaz/archive.zig) was considered:
   it has no bzip2, its "lzma" is a private codec with an LZMA-alone header
   (its source says the payload is "not range-coded LZMA"), so it cannot read real
   `.lzma` files, and it would add three dependencies.
2. **`-f` is whatis, `-k` is apropos, the browser moved to `-b`.** This breaks
   `dkman -f` of 0.3.x (hence version 0.4.0). **review:** the other choice is
   keeping `-f` as browser and being incompatible with man for scripts.
3. **Descriptions come from the NAME section**, found in the rendered text of
   the preamble and first section only (about 4 times faster than rendering
   whole pages in a debug build; a release build indexed 4100 pages in 1.3 s on
   the development machine). They are
   cached per set of manual directories in `$XDG_CACHE_HOME/dkman/`; the cache
   is stale when the modification time of a manual directory or one of its
   `manS` directories changes. It is not rebuilt when a page file is edited in
   place (man-db's `mandb` has the same limit); `--update-index` forces it.
4. **Without color the output is plain text.** md-zig's uncolored mode writes
   Markdown markers (`## NAME`, `**x**`); render always draws styled text and
   strips the escape sequences when color is off.
5. **Exit codes are man-db's** (1 usage, 2 failure, 16 not found) and the
   messages are man's (`No manual entry for X`), without a program-name prefix.
6. **`MANPATH` derivation, `MANSECT`, `MANPAGER`, `MANWIDTH`, locale** follow
   man-db's documented behavior (man-db 2.x man page, `man(1)` ENVIRONMENT, and
   `/etc/manpath.config`). Only `MANDATORY_MANPATH`, `MANPATH_MAP` and
   `SECTION` of the config file are read.
7. **ASCII output when the locale is not UTF-8**, as man does; `--ascii` forces
   it.

8. **Regular expressions come from regex-zig** (release 0.1.0, fetched by URL
   like md-zig and gtroff-zig): the new `.posix_ere` dialect, ignoring case,
   with its default limits, so a hostile pattern ends in an error that is
   treated as "no match". A word that does not compile is searched for as
   plain text. regex-zig gained that dialect for this (see its
   `docs/compatibility/posix_ere.md`); it is not yet checked against
   `regcomp`, and it is leftmost-first, which cannot change whether a word
   matches. Shell wildcards for `--wildcard` are in `glob.zig` because
   regex-zig does not cover them.
9. **Page names ignore case by default**, as in man-db (`-I` to match case).
10. **A miss suggests names** within one or two typos (swapping neighbours
    counts as one), only the closest group, none for names of two letters or
    less and none when the page exists but was filtered out.
11. **The browser searches descriptions** from the same index: a word matches a
    name or a description; description matches rank above letters merely found
    in order in a name, and below any match inside a name.

12. **The index follows man-db's records** (checked against man-db 2.13.1 on
    the same page tree with `test/tools/compare_man.sh` and by comparing
    `whatis` output): one entry per page file, listed under the file's name;
    the names the NAME section declares are further keys, except for links and
    `.so` stubs, which stand for their own name only; a NAME section with several
    `name - description` lines gives the page the line that declares its file
    name; lookups let a file called exactly the name win over declaring pages;
    listings keep the first page of each name and section, pad the name column
    to 20 and cut to the terminal width. `man -w`/`-a` follow links and `.so`
    and, with no file of that name, find pages that declare it. Result on 800
    random names: `man -w` agrees with man-db on all; `whatis` output agrees on
    142 of 150 (the rest are mostly pages whose NAME text differs between the
    two programs or a stale man-db database); `apropos` result counts are
    within about 5%.
13. **Companion commands by `argv[0]`**: `whatis`, `apropos`, `manpath`, `mandb`
    are the same program (see the man page, COMPANION COMMANDS). `MANOPT` is
    honored for `man`. `-t` and `-T` are refused.
14. **zstd frames declare a window**; the buffer is sized from the frame header,
    up to 128 MiB (the reference decoder's default limit). Found by
    `test/tools/compress_roundtrip.sh` (2000 recompressed pages, no failures
    after the fix).

## Not done

Hyphenation (groff's patterns are GPL data), POSIX ERE syntax,
`mandb` databases and `cat` pages, `-E` encodings other than UTF-8/ASCII,
`-C`, `-D` and the other man-db options (rejected as usage errors).
`gtroff-zig` leaves `\(aq` unresolved in some pages (seen in uutils pages); that
is a gtroff-zig issue.

15. **Layout like groff's** (compared with man-db's output line by line):
    justified text (`md-zig` 0.5.0 `TextOptions.justify`, the extra spaces
    alternating between the two ends of a line), no blank line under a section
    heading (`tight_headings`, md-zig 0.6.0), and groff's header and footer lines
    made from the `.TH` (or `.Dt`/`.Os`/`.Dd`) line (`render.zig`). On 40 random
    pages 57% of lines are identical to man-db's; most of the rest differ by a
    hyphenated word or a page's own margins. Strings with escapes in them
    (`.ds Aq \(aq`) are now read when used (gtroff-zig 0.5.0).

## Consequences

- `paths.find`, `paths.sortByPreference` and `paths.searchDirs` take extra
  arguments; library users must update. `source.Error.BadGzip` is now
  `BadCompression`.
- Pages from every locale directory are only used when the locale asks for it.

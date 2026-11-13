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
   gzip, xz and zstd are decoded with `std.compress`. bzip2 is not in the
   standard library, and lzma has no magic number: those two run the system
   `bzip2` / `xz` with a fixed argument vector (no shell, path after `--`).
   **review:** this is the first external program dkman runs besides the pager;
   decision 0001 (4) said "no required external program". It is only needed
   for those two rarely used formats; the alternative is to write a bzip2
   decoder.
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

## Not done

Justification and hyphenation, regular expressions and wildcards for `-k`/`-f`,
`mandb` databases and `cat` pages, `-E` encodings other than UTF-8/ASCII,
`-C`, `-D` and the other man-db options (rejected as usage errors).
`gtroff-zig` leaves `\(aq` unresolved in some pages (seen in uutils pages); that
is a gtroff-zig issue.

## Consequences

- `paths.find`, `paths.sortByPreference` and `paths.searchDirs` take extra
  arguments; library users must update. `source.Error.BadGzip` is now
  `BadCompression`.
- Pages from every locale directory are only used when the locale asks for it.

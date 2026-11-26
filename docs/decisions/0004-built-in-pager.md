# 0004: A built-in pager, the default everywhere

Status: accepted (2026-11-25).

## Context

The default pager was `less`, with `more.com` as the fallback on Windows, where
`less` is not installed. On Windows 11 (build 22631), over SSH, `more.com`
showed UTF-8 as code page 437 text. With the console set to code page 65001 it
dropped the horizontal border lines of tables.

## Decision

The default pager on every system is the one util-core 0.2.0 has for `less` and
`cat`. `-P`, `MANPAGER` and `PAGER` still choose another. A configured pager
that cannot be started gives way to the built-in one.

- util-core's library has the pager's model (`util_core.pager`: text, wrapping,
  keys, search, drawing). It does not export the terminal driver, so dkman runs
  the terminal itself, with the code `-b` already uses (`src/console.zig`).
- Keys are read from the terminal opened by name (`/dev/tty`, `CONIN$`), so a
  page can come through a pipe.
- Only the program imports util-core. The library module does not.

## Consequences

- No other program has to be installed.
- A user who relied on `less` features or `LESS` options must now set
  `MANPAGER` or `PAGER`.
- util-core is GPL-2.0-or-later. dkman, which was MIT through 0.6.1, takes the
  same license, program and library alike. Release archives need the GPL text
  and a way to get the source.
- The pager counts every character as one column, so lines with double-width
  characters (CJK, many emoji) can be cut at the right edge.

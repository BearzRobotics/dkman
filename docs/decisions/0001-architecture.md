# 0001: Architecture of dkman

Status: accepted by the maintainer in conversation.

## Problem

dkde needs a manual page tool that finds pages in the traditional places, reads
the classic roff formats and the project's own Markdown documentation, searches
with a built-in browser, and shows pages in a pager. See md-zig decision 0002 for the split
between libraries.

## Decisions

1. **dkman is the only program and the only renderer.** Readers produce an
   `md.Node` tree; md-zig writes the terminal text. Markdown is read by md-zig,
   roff (man and mdoc) will be read by gtroff-zig.
2. **Lookup follows man(1):** `MANPATH` or the default directories, section
   directories `manS` (with subsections such as `3p`), files `NAME.S[.md][.gz]`,
   preferred section order `1 n l 8 3 0 2 5 4 9 6 7`.
3. **Format is detected from the name and the first macro line**, not the
   directory (`format.zig`).
4. **No shell.** The pager is started directly with an argument vector.
   There is no required external program: `-f` is a built-in terminal browser
   (search box left, preview right) and needs no fzf.
5. **Search is by name** for now. A page-description index (`whatis`) needs a
   reader for the NAME section and is deferred.

## Alternatives considered

- Shell out to `man`/`groff`: adds dependencies and hides errors, and cannot
  show Markdown.
- Separate renderers per format: two looks, more code.

## Consequences

- dkman depends on md-zig and gtroff-zig (path dependencies for now).
- man(7) and mdoc(7) both work through gtroff-zig; fidelity is limited to what the shared tree can express.

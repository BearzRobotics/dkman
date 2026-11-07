# NAME

dkman - find, search and show manual pages and Markdown documents

# SYNOPSIS

    dkman [options] [SECTION] NAME...
    dkman [options] -l FILE...
    dkman -k WORD
    dkman -f [WORD]

# DESCRIPTION

`dkman` looks for manual pages in the traditional directories, picks the reader
from the file name and content, and shows the result through a pager. Pages may
be gzip compressed. Markdown documents (`NAME.SECTION.md`) are found like any
other page, so a project can install its own documentation next to the system's.

Classic roff pages (man(7) and mdoc(7)) are recognised, but showing them needs
gtroff-zig, which is not linked in yet: `dkman` reports that and exits with 1.

# OPTIONS

`-l FILE`
: Show a file given by path. `-` reads standard input.

`-w`
: Print the path of the page instead of showing it.

`-k WORD`
: List pages whose name contains WORD, as `name(section)` and path.

`-f [WORD]`
: Choose a page with fzf. The list is every page found; the preview pane shows
  the page. WORD is the first query.

`--width N`
: Wrap at N columns. Default: `COLUMNS`, else 80.

`--no-color`
: No ANSI styles. They are also off when standard output is not a terminal or
  `NO_COLOR` is set to a non-empty value.

`--no-pager`
: Write to standard output. The pager is only used on a terminal.

`-h`, `--help`
: Print usage to standard error and exit with 2.

A name containing a slash is taken as a path. A first operand that looks like a
section (`3`, `3p`, `n`) followed by a name selects that section.

# EXIT STATUS

0 on success, 1 if a page was not found or could not be read, 2 for a usage
error.

# ENVIRONMENT

`MANPATH`
: Colon separated manual directories. An empty entry stands for the defaults.

`PAGER`
: Pager command, split at blanks, no shell. Default `less -R`. If it cannot be
  started the text is written to standard output.

`COLUMNS`, `NO_COLOR`
: See `--width` and `--no-color`.

# FILES

`/usr/local/man`, `/usr/local/share/man`, `/usr/share/man`, `/usr/man`
: Default manual directories. Each holds `man1` ... `man9`, `mann`, `manl` and
  subsections such as `man3p`.

# EXAMPLES

    dkman 3 printf
    dkman -l README.md
    dkman -k zstd
    dkman -f

# LIMITATIONS

- Search matches page names only; there is no `whatis` database yet.
- `-f` needs fzf in `PATH`.
- Without a section, the page is chosen in the order `1 n l 8 3 0 2 5 4 9 6 7`,
  then by directory order.

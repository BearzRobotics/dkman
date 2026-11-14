# NAME

dkman - find, search and show manual pages and Markdown documents

# SYNOPSIS

    dkman [options] [SECTION] NAME...
    dkman [options] -l FILE...
    dkman -f NAME...
    dkman -k WORD...
    dkman -K WORD...
    dkman -b [WORD]

# DESCRIPTION

`dkman` looks for manual pages in the traditional directories, picks the reader
from the file name and content, and shows the result through a pager. Pages may
be compressed with gzip, xz, zstd, bzip2 or lzma. Markdown documents
(`NAME.SECTION.md`) are found like any other page, so a project can install its
own documentation next to the system's.

Classic man(7) and mdoc(7) pages are read by gtroff-zig and drawn with the same
renderer as Markdown. Section bodies are indented like groff's terminal output,
and tagged paragraphs, lists, tbl tables, user-defined macros and number
registers are handled. Layout is still approximate (text is not justified and
tables are drawn as grids). A page that only says `.so man1/other.1` shows the
page it names.

The page is chosen by section order, then by directory order. `NAME(SECTION)`
and a leading section operand (`dkman 3 printf`) select a section.

# OPTIONS

`-l`, `--local-file FILE`
: Show a file given by path. `-` reads standard input.

`-s`, `-S`, `--sections LIST`
: Only look in these sections. LIST is separated by colons or commas, and its
  order is the order they are tried in. `3` includes `3p`.

`-a`, `--all`
: Show every matching page, not only the first. With `-k`, a page must match
  all the words.

`-I`, `--match-case`, `-i`, `--ignore-case`
: Page names are compared ignoring ASCII case by default, so `dkman LS` finds
  `ls`. `-I` makes them case sensitive.

`-e`, `--extension EXTENSION`
: Only pages whose section ends in EXTENSION: `-e perl` selects `3perl`.

`-H`, `--html`
: Write HTML instead of terminal text, to standard output.

`-w`, `--where`, `--path`
: Print the path of the page instead of showing it. A page that is a symbolic
  link or only says `.so other` stands for the file it leads to, as in man-db.
  Without a name, print the manual directories.

`-f`, `--whatis NAME...`
: One line for every page called NAME: `name (section) - description`. A page
  is found by its file's name and by every name its NAME section declares. A
  page that is a link or a `.so` stub to another is listed under its own name.
  A page file called exactly NAME takes the place of the pages that only
  declare the name. Lines are cut to the terminal width and end in `...`; the
  name column is 20 wide, as in man-db.

`-k`, `--apropos WORD...`
: List pages whose name or description matches any of the words, ignoring case.
  Each word is a regular expression (`-r`, the default). A word that is not a
  valid expression is searched for as text.

`-l`, `--long` (as `whatis` or `apropos`)
: Do not cut lines to the width.

`-r`, `--regex`, `--wildcard`, `--exact`
: How `-f` and `-k` compare words. `--regex`: a regular expression, found
  anywhere (POSIX extended syntax with the GNU `\w \s \b` escapes, from
  regex-zig; a pattern that takes too long counts as no match). `--wildcard`: a shell wildcard (`*`, `?`, `[a-c]`) that must match the
  whole name or a whole word of the description. `--exact`: the whole name or a
  whole word. The default for `-f` is `--exact`, for `-k` `--regex`.

`-K`, `--global-apropos WORD...`
: List pages whose text contains all of the words. Reads every page: slow.

`-b`, `--browse [WORD]`
: Browse pages. The search box and the matching pages are on the left, a
  preview of the selected page is on the right, headed by the page's name,
  description and path. WORD is the first search text. Several words must all
  match, each in the page name (typing letters in order is enough) or in its
  one-line description; name matches rank first. The descriptions come from the
  index of `-f`/`-k`, built on first use. Keys: `Up`/`Down` (`Ctrl-P`/`Ctrl-N`) select,
  `PgUp`/`PgDn` scroll the preview, `Home`/`End` jump in it, `Enter` opens the
  page in the pager and returns here afterwards, `Esc` or `Ctrl-C` leaves.
  Needs a terminal.

`-M`, `--manpath PATH`
: Colon separated manual directories, instead of `MANPATH`.

`-L`, `--locale LOCALE`
: Prefer pages in this language (`de_DE.UTF-8` looks in `DIR/de_DE`, `DIR/de`,
  then `DIR`). Default: the first of `LC_ALL`, `LC_MESSAGES`, `LANG`.

`-P`, `--pager COMMAND`
: Pager command. Default: `MANPAGER`, `PAGER`, then `less`.

`--width N`
: Wrap at N columns. Default: `MANWIDTH`, `COLUMNS`, the terminal's width, 80.

`--ascii`, `-7`
: ASCII characters only: dashes, quotes and bullets are replaced, boxes are drawn
  with `+-|`. This is the default unless the locale (`LC_ALL`, `LC_CTYPE`,
  `LANG`) names UTF-8.

`--color`, `--no-color`
: Pages are shown in color on a terminal (headings yellow, options and commands
  green, arguments cyan, code magenta, page references bold magenta). `--color`
  forces it; `--no-color` turns it off. It is also off when standard output is
  not a terminal or `NO_COLOR` is set to a non-empty value. Without color the
  text is plain, as with man(1).

`--no-pager`
: Write to standard output. The pager is only used on a terminal.

`--update-index`
: Rebuild the cache of page descriptions that `-f` and `-k` read.

`-V`, `--version`
: Print the version.

`-h`, `--help`, `-?`
: Print usage to standard error and exit with 1.

`-E`, `--nh`, `--nj`
: Accepted and ignored, for scripts written for man(1).

A name containing a slash is taken as a path. Short options can be combined
(`-aw`) and take their value attached or as the next word (`-s3`, `-s 3`). `--`
ends the options.

# COMPANION COMMANDS

Started as `man`, `whatis`, `apropos`, `manpath` or `mandb`, dkman acts as the
man-db command of that name: `whatis` is `-f`, `apropos` is `-k`, `manpath` is
`-w` without a name, `mandb` is `--update-index`. In `whatis` and `apropos`,
`-w` is `--wildcard`, `-e` is `--exact`, `-r` is `--regex`, `-l` is `--long`.
`mandb` and `manpath` accept and ignore man-db's other options. `-V` and `-h`
work in all of them. `zig build -Dinstall-as-man` installs the commands.

# EXIT STATUS

0 on success, 1 for a usage error, 2 if a page could not be read, 16 if no page
(or no `-f`/`-k`/`-K` match) was found. These are man-db's codes. When a page is
not found, similar names are suggested on standard error (`Did you mean: ...`).

# ENVIRONMENT

`MANPATH`
: Colon separated manual directories. An empty entry stands for the directories
  below. If it is not set, they are found as man-db does: every directory of
  `PATH` implies one (through `MANPATH_MAP` in `/etc/manpath.config`, or
  `.../bin` giving `.../man` and `.../share/man`), then the `MANDATORY_MANPATH`
  entries. Only directories that exist are used.

`MANSECT`
: Colon separated sections in the order they are tried. Default: the `SECTION`
  line of `/etc/manpath.config`, else `1 n l 8 3 0 2 5 4 9 6 7`.

`MANPAGER`, `PAGER`
: Pager command, split at blanks, no shell. A `less` without an option that
  passes colors through gets `-R`. If the pager cannot be started the text is
  written to standard output.

`MANWIDTH`, `COLUMNS`, `NO_COLOR`
: See `--width` and `--color`.

`LC_ALL`, `LC_MESSAGES`, `LC_CTYPE`, `LANG`
: Language of the pages and character set of the output.

`XDG_CACHE_HOME`, `HOME`
: The page descriptions are cached in `$XDG_CACHE_HOME/dkman/` or
  `~/.cache/dkman/`, and in `/var/cache/dkman/` (see FILES). The cache is
  rebuilt when a manual directory is added to or removed from (or
  `--update-index` is given).

# FILES

`/var/cache/dkman/`
: A system-wide index of page descriptions. `mandb` (or `dkman --update-index`)
  run as a user who can write there makes it; everyone reads it when it is
  current, and builds their own cache otherwise. A package should run `mandb`
  after installing or removing pages.

`/etc/manpath.config`, `/etc/man_db.conf`
: Read for `MANDATORY_MANPATH`, `MANPATH_MAP` and `SECTION`.

`/usr/local/man`, `/usr/local/share/man`, `/usr/share/man`, `/usr/man`
: Manual directories used when nothing else is found. Each holds `man1` ...
  `man9`, `mann`, `manl` and subsections such as `man3p`.

# EXAMPLES

    dkman 3 printf
    dkman 'printf(3)'
    dkman -a printf
    dkman -l README.md
    dkman -f printf
    dkman -k zstd
    dkman -b

# LIMITATIONS

- Output is checked against groff by comparing the words of a sample of installed
  pages, not the layout. Text is not justified or hyphenated.
- bzip2 and lzma pages are read by running the system's `bzip2` and `xz`
  programs; gzip, xz and zstd are read in process.
- Regular expressions are POSIX extended (regex-zig 0.1.0), but the engine is
  leftmost-first and lacks `\<`, `\>` and `[[.x.]]`; as dkman only asks whether a
  word matches, this makes no difference to the results. `-K` matches text, not
  expressions.
- Pages are not cached as `cat` pages and `mandb` databases are not read: dkman
  keeps its own index, built from the NAME sections. It agrees with man-db's
  `whatis` on most pages (142 of 150 sampled names on one machine, the rest
  differing mostly where the two databases were built from different files).
- `-b` needs a terminal 70 columns wide or more to show the preview.
- Built and tested on Linux. It compiles for macOS and the BSDs (the terminal
  size and raw mode use the same POSIX calls), but has not been run there.
- Output encoding is UTF-8 or ASCII only (`-E` is ignored).

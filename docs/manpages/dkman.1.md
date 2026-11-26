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
be compressed with gzip, xz, zstd, bzip2 or lzma; all are decoded by dkman itself. Markdown documents
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
: Pager command. Default: `MANPAGER`, `PAGER`, then the built-in pager
  (see **PAGER**). An empty command means no pager.

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

`--set` LIST
: Look only in the downloaded documentation sets LIST names (comma separated; see
  DOCUMENTATION SETS). Each name is a set id (`powershell-5.1`), the start of
  one before a dash (`powershell`, `winps`), a topic (`Windows Server`) or a
  version (`5.1`, `2022`). The man directories are not searched. With `-k`,
  `-f` and `-b` it narrows the listing the same way.

`--docs-dir` DIR
: Use DIR as your documentation folder (also set by the `DKMAN_DOCS`
  environment variable). Downloaded sets are kept in `DIR/dkman`; your own
  pages anywhere else below DIR are found too: every Markdown file (`GUIDE.md`
  is the page `GUIDE` in section `doc`, `tool.1.md` the page `tool` in section
  1) and every man page (`rg.1`, `foo.8.gz`). A loose page can also be found
  by the names of the folders it is in (`dkman -k ripgrep`). Folders starting
  with a dot and those listed in `DIR/.dkmanignore` (one per line, below DIR;
  `#` starts a comment) are not read. A page added deep in a folder is seen
  after `--update-index`. For a toolkit carried on a USB drive:
  `dkman --docs-dir E:\\docs --fetch-docs all` once, then
  `set DKMAN_DOCS=E:\\docs` on any machine. The page index is kept in
  `DIR/dkman/.cache`, so it travels with the documentation and the host
  machine is not written to. Only directories with a `dkman-set` file are
  ever replaced by `--fetch-docs`. A DIR that already holds sets directly
  (dkman 0.6.0) keeps them there.

`--list-docs`
: List the documentation sets that can be downloaded, with their topic, version,
  download size and whether they are installed.

`--fetch-docs` SET...
: Download documentation sets (see DOCUMENTATION SETS). A SET is selected as
  for `--set`; `all` takes every set. A repository that cannot be downloaded
  is tried three times, then skipped; the other sets are installed and
  indexed, and the exit status is 1. Running the command again retries.

`--no-pager`
: Write to standard output. The pager is only used on a terminal.

`--update-index`
: Rebuild the cache of page descriptions that `-f` and `-k` read. Each
  downloaded set keeps its own descriptions in a `dkman-index` file, made the
  first time the set is indexed (reading every page: minutes for `all` on a
  slow USB drive); later rebuilds read that file instead. Delete it to have
  the set read again.

`-V`, `--version`
: Print the version.

`-h`, `--help`, `-?`
: Print usage to standard error and exit with 1.

`-E`, `--nh`, `--nj`
: Accepted and ignored, for scripts written for man(1).

A name containing a slash is taken as a path. Short options can be combined
(`-aw`) and take their value attached or as the next word (`-s3`, `-s 3`). `--`
ends the options.

# DOCUMENTATION SETS

Microsoft publishes its documentation as Markdown in public GitHub
repositories (github.com/MicrosoftDocs). `dkman --fetch-docs` downloads the
archive of a repository, keeps only the pages a set wants and stores them as
ordinary manual directories, so every mode of dkman (`-k`, `-f`, `-b`, `-w`,
`--set`) works on them without being online. Nothing is installed by default:
Windows ships almost no offline help. No other program (git, curl, PowerShell)
is needed, and sets of one repository share one download. The download is of
the whole repository, from a few megabytes to about a gigabyte
(`--list-docs` shows each); a failed download leaves the old copy in place.

Pages are in sections: `ps` (cmdlets and about topics), `cmd` (Windows
commands), `ws` (Windows Server guides), `psguide` (PowerShell guides), `sys`
(Sysinternals), `wsl`, `win32` (API functions, structures, enumerations: the sdk-api
repository) and `winguide` (Win32 and COM guides).
The section may come first, as with numbers: `dkman ps Get-ChildItem`,
`dkman cmd robocopy`, `dkman -s ps -k firewall`. Guides are named by their
folders (`identity-ad-ds-...`), found with `-k`.

The sets, by topic:

PowerShell
: `powershell-5.1`, `-7.4`, `-7.5`, `-7.6`, `-7.7` (cmdlets and about
  topics), `powershell-guide`, `psmodules` (PSScriptAnalyzer,
  SecretManagement, PlatyPS, Crescendo), `dsc-1.1`, `-2.0`, `-3.0`,
  `psget-2.x`, `psget-3.x`, `psget-guide`.

Windows Server
: `winps-2016`, `-2019`, `-2022`, `-2025` (the Windows modules: Hyper-V,
  ActiveDirectory, DnsServer, NetAdapter ...), `cmd`, `winserver` (AD DS, AD FS,
  DNS, Hyper-V, remote access, Admin Center, storage, performance tuning ...).

Microsoft 365
: `exchange`, `teams`, `skype`, `office-misc`, `sharepoint-online`; also
  `sharepoint-server`.

Others
: `sysinternals`, `wsl`, `win32` (API reference), `win32-guide`.

Search by version with `--set`: `dkman --set 5.1 -k firewall` looks only in
Windows PowerShell 5.1's documentation, `--set winps-2022` in Windows Server
2022's modules, `--set "Windows Server"` in everything about the server.

# WINDOWS

dkman runs on Windows (a console with ANSI support: Windows Terminal, or
conhost of Windows 10 and later). Differences from other systems:

- Path lists (`MANPATH`, `-M`, `PATH`) are separated by `;`.
- The manual directories used without `MANPATH` are those implied by `PATH`
  (a `bin` directory implies the `man` and `share\man` beside it) plus, when
  they exist, the man trees of Git for Windows (`Git\usr\share\man`,
  `Git\mingw64\share\man`), MSYS2 and Cygwin (`C:\msys64`, `C:\cygwin64`),
  Scoop apps (`%USERPROFILE%\scoop\apps\*\current`), rustup toolchains and the
  downloaded documentation sets.
- The built-in pager is the default, so nothing needs installing. `more.com`
  is not used on its own: it garbles or drops UTF-8 text.
- Output is UTF-8 on a console (dkman sets the code page) and ASCII when
  redirected, unless `--ascii` or the locale says otherwise.
- The page index is cached in `%ProgramData%\dkman\cache` (written by
  `mandb` run as administrator) and `%LOCALAPPDATA%\dkman\cache`; downloaded
  documentation lives in `%LOCALAPPDATA%\dkman\docs`; `%ProgramData%\dkman\manpath.config` is
  read like `/etc/manpath.config`.
- A page argument with a backslash or a drive letter is a path.

# PAGER

Unless a pager is configured, pages are shown by the built-in pager, the
`less` of util-core, on every system. It needs a terminal that takes ANSI
styles; otherwise the text is written to standard output.

- `Space`, `f` or Page Down: a page down; `b` or Page Up: a page up.
- `d` and `u`: half a page. `j`, `Enter` or Down, and `k` or Up: one line.
- `g` or Home: the top; `G` or End: the bottom.
- `/` and `?` search forward and backward, `n` and `N` repeat. A pattern in
  lower case ignores case.
- `=` shows the position, `h` the keys. `q` or `Ctrl-C` quits.

The search is for plain text, not a regular expression. For another pager,
use `-P`, `MANPAGER` or `PAGER` (for example `-P less`).

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
: Manual directories, separated by colons (semicolons on Windows). An empty entry stands for the directories
  below. If it is not set, they are found as man-db does: every directory of
  `PATH` implies one (through `MANPATH_MAP` in `/etc/manpath.config`, or
  `.../bin` giving `.../man` and `.../share/man`), then the `MANDATORY_MANPATH`
  entries. Only directories that exist are used.

`MANSECT`
: Colon separated sections in the order they are tried. Default: the `SECTION`
  line of `/etc/manpath.config`, else `1 n l 8 3 0 2 5 4 9 6 7`.

`MANPAGER`, `PAGER`
: Pager command, split at blanks, no shell. A `less` without an option that
  passes colors through gets `-R`. If the pager cannot be started, the
  built-in pager is used.

`MANWIDTH`, `COLUMNS`, `NO_COLOR`
: See `--width` and `--color`.

`LC_ALL`, `LC_MESSAGES`, `LC_CTYPE`, `LANG`
: Language of the pages and character set of the output.

`DKMAN_DOCS`
: The directory of downloaded documentation (see `--docs-dir`).

`XDG_DATA_HOME`, `LOCALAPPDATA`, `ProgramData`
: Where downloaded documentation (`$XDG_DATA_HOME/dkman/docs`,
  `~/.local/share/dkman/docs`, `%LOCALAPPDATA%\dkman\docs`) and, on Windows, the
  caches and configuration file are kept.

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
  pages, and its layout line by line against man-db's. Text is justified like
  groff's, but words are never hyphenated (groff's hyphenation patterns are
  not part of dkman), so some lines break differently. `--nj` leaves the right
  margin ragged.
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
  size and raw mode use the same POSIX calls), but has not been run there. The
  Windows build is tested under Wine; the console functions (ANSI and UTF-8
  setup, window size, the `-b` browser's raw input) have not been run on a real
  console.
- Downloaded documentation is Markdown meant for a web page: HTML fragments in
  tables and Learn-specific syntax (`> [!NOTE]`, tabs) show as written.
- Output encoding is UTF-8 or ASCII only (`-E` is ignored).

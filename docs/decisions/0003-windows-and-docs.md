# 0003: Windows, and offline Microsoft documentation

Status: requested by the maintainer ("get windows support in", "I want a full
toolkit ... in the field I can find what I need when I need it"); the choices
marked **review** were the assistant's.

## Problem

dkman only ran where `/usr/share/man` is. On Windows almost no help is installed
(PowerShell's cmdlet help is downloaded by `Update-Help` as MAML XML, `cmd`
help is a program, and most tools ship nothing), but Microsoft publishes all of
it as Markdown in github.com/MicrosoftDocs, which dkman already reads.

## Decisions

1. **Platform code is in two small modules.** `console.zig` (window size, ANSI
   and UTF-8 setup, raw key input for `-b`, using kernel32 and virtual terminal
   sequences so the browser sees the bytes it sees on POSIX) and `platform.zig`
   (path-list separator, Windows man trees, data/cache/config locations). The
   rest of dkman is unchanged apart from path handling (`;`, drive letters,
   backslashes) in `paths.zig`.
2. **Documentation is downloaded, not bundled** (`--fetch-docs`), by an in-process
   HTTPS download of the GitHub archive (`std.http`, `flate`, `tar`): no git,
   curl or PowerShell needed, nothing installed by default (size, and licensing
   of the content stays Microsoft's). A set is a path filter over one repository
   (`docsets.zig`); sets of one repository share a download; only `.md` files
   are kept; a set is written to `.SET.new` and swapped in. **review:** the
   download is of the whole repository (windowsserverdocs is large); git
   sparse checkout would be smaller but needs git.
3. **Fetched pages are written in man's layout** (`SET/manps/NAME.ps.md`), so
   scanning, the index, `-k`, `-f`, `-b` and `-w` needed no new code. Sections
   are `ps`, `cmd`, `ws`, `psguide`, `sys`, `wsl`, `win32`; a leading
   section word is accepted for them (`dkman ps Get-Item`).
4. **Names:** cmdlet, command and tool pages by file name; guides by their
   folder path (`identity-ad-ds-...`) because their file names repeat;
   Win32 API pages by the `UID:` in their front matter. The API reference
   is in the `sdk-api` repository, not `win32` (which holds the conceptual
   guides, set `win32-guide`; found when the first attempt read 48,000 pages and
   kept 103). **review:** guide names are
   long; `-k` is the way to find them.
5. **Versions are separate sets** (`powershell-5.1`, `winps-2022`) searched with
   `--set` (id, family, topic or version) rather than merged, since the same
   cmdlet differs between versions. Each set has a `dkman-set` manifest (id,
   topic, version, title, page count) for tools such as dkde-help that group
   by topic.
6. **Descriptions** for the index come from SYNOPSIS, else the front matter's
   `description`, else the first paragraph (`whatis.docSummary`); the index
   format version was raised so old caches are rebuilt.
7. **`--docs-dir` / `DKMAN_DOCS`** keep the documentation anywhere (a toolkit
   USB drive). The page index is then written to `DIR/.cache` first, not to
   the host's cache, so it travels with the docs. The index stores absolute
   paths, so a different drive letter rebuilds it.
   **Per-set index (0.6.1).** Building the index means reading every page,
   and on a USB flash drive a cold read costs about 10 ms a file (measured
   with a SanDisk 3.2 Gen1 stick: `winps-2025`, 3825 pages, took 43 s cold and
   2 s warm). `all` is about 135 000 pages, so the first index after a fetch
   took 20 minutes with no output and was taken for a hang; interrupting it
   lost everything, so the next search started again from nothing. Each set
   now keeps its entries in its own `dkman-index` file (paths relative to the
   set, written with `/`), made the first time the set is indexed. A set never
   changes once installed (a download replaces the whole directory), so the
   file needs no fingerprint, only a format version. The main index is then
   built from these files in seconds, also after a drive-letter change or
   with `--set`; an interrupted build keeps the sets already done. A build
   reports each directory of 1000 pages or more on standard error (with a
   running count on a terminal). Alternatives: reading pages in parallel
   threads (helps a flash drive somewhat, but every rebuild still reads
   everything), or computing descriptions while downloading (no extra read,
   but pages already installed would still need this path, and a page
   written twice under one name would need its own bookkeeping).
   **Downloads (0.6.1).** A repository whose download fails (a connection
   dropped mid-archive, a file another program holds) is tried three times
   and then skipped; the other repositories are still installed and indexed,
   and the command exits 1 naming the sets to fetch again. Moving a finished
   set into place is retried for up to 10 s, since on Windows a virus scanner
   or the search indexer often still holds files just written. A single page
   that cannot be written is reported and left out.
   **A documentation folder of one's own (0.6.1).** `--docs-dir` was the sets'
   directory, and every directory in it was searched as a set, so pointing it
   at a folder that also holds one's own documents mixed them in, and a
   fetch deleted any directory with a set's name. Now the folder is the
   user's: sets go in its `dkman` subdirectory (a folder that already holds
   sets keeps them, for 0.6.0 installs), only directories with a manifest are
   sets or are ever replaced, and the rest of the folder is read for loose
   pages (`paths.scanLoose`): Markdown files (section `doc` unless the name
   carries one) and man pages, their folder names being further search keys.
   `.dkmanignore` lists folders to leave out (a cloned documentation
   repository already downloaded as a set, say). The fingerprint covers the
   folder and its top-level folders only, since walking a large tree at
   every search would be slow on a USB drive; deeper additions need
   `--update-index`.
8. **Not done:** `Update-Help` MAML (`*-help.xml`) and `about_*.help.txt`
   already installed by Windows PowerShell; real-console testing of the
   Windows console functions; Azure and Microsoft Graph PowerShell,
   windows-dev-docs, windows-driver-docs and Windows Terminal docs (very large
   or developer-oriented); Learn syntax (`> [!NOTE]`, tabs) is shown as written.

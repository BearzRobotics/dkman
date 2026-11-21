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
   paths, so a different drive letter rebuilds it (about 30 s for everything).
8. **Not done:** `Update-Help` MAML (`*-help.xml`) and `about_*.help.txt`
   already installed by Windows PowerShell; real-console testing of the
   Windows console functions; Azure and Microsoft Graph PowerShell,
   windows-dev-docs, windows-driver-docs and Windows Terminal docs (very large
   or developer-oriented); Learn syntax (`> [!NOTE]`, tabs) is shown as written.

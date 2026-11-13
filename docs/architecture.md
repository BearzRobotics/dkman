# Architecture

    argv --> main.zig --> paths.zig (MANPATH, sections) --> page path
                 |                                              |
                 |                         source.zig (read, decompress)
                 |                                              |
                 |                         format.zig (markdown | man | mdoc | plain)
                 |                                              |
                 |                         render.zig --> md-zig / gtroff-zig --> text
                 |                                              |
                 +--> search.zig (listing), tui.zig      pager.zig (PAGER or stdout)

| File | Role |
|---|---|
| `main.zig` | Argument parsing (table driven), environment, modes (show, `-l`, `-w`, `-f`, `-k`, `-K`, `-b`), exit codes |
| `paths.zig` | Manual directories (`MANPATH`, derived from `PATH` and `/etc/manpath.config`, locale), section order, scanning `manS` directories, choosing pages |
| `source.zig` | Reads a file, undoes gzip, xz and zstd in process (bzip2, lzma through the system programs), found by magic bytes; bounded by `max_bytes` |
| `format.zig` | Decides the format from file name and first macro line |
| `render.zig` | One entry point from format and bytes to terminal text |
| `search.zig` | Sorting and listing pages (`-b`, `-K`), similar-name suggestions |
| `whatis.zig` | NAME-section descriptions, the cached index, `-f` and `-k` matching (regex-zig for expressions) |
| `glob.zig` | Shell wildcards for `--wildcard` |
| `tui.zig` | The `-f` browser: search box, page list and preview, fuzzy matching, raw terminal |
| `theme.zig` | Restyles md-zig's colored output: headings, options, arguments, code, page references |
| `page.zig` | Loads one page for display (stdin, `.so` redirects, format) |
| `pager.zig` | Splitting the pager command (`less` gets `-R`), piping text into it, falling back to stdout |

Tests live next to the code (`zig build test`).

## Library use

`build.zig` exports the module `dkman` (`src/root.zig`), which re-exports
`paths`, `source`, `format`, `render`, `search`, `theme`, `page`, `whatis` and `glob`. `render.parse` returns an
`md.Document` for callers that draw the page themselves (the dkde help viewer);
`render.render` writes terminal text. `main.zig`, `pager.zig` and argument
handling stay in the program.

# Architecture

    argv --> main.zig --> paths.zig (MANPATH, sections) --> page path
                 |                                              |
                 |                         source.zig (read, gunzip)
                 |                                              |
                 |                         format.zig (markdown | man | mdoc | plain)
                 |                                              |
                 |                         render.zig --> md-zig / gtroff-zig --> text
                 |                                              |
                 +--> search.zig (listing), tui.zig      pager.zig (PAGER or stdout)

| File | Role |
|---|---|
| `main.zig` | Argument parsing, modes (show, `-l`, `-w`, `-k`, `-f`), exit codes |
| `paths.zig` | Manual directories, scanning `manS` directories, choosing a page |
| `source.zig` | Reads a file, undoes gzip; bounded by `max_bytes` |
| `format.zig` | Decides the format from file name and first macro line |
| `render.zig` | One entry point from format and bytes to terminal text |
| `search.zig` | Sorting and listing pages (`-k`) |
| `tui.zig` | The `-f` browser: search box, page list and preview, fuzzy matching, raw terminal |
| `theme.zig` | Restyles md-zig's colored output: headings, options, arguments, code, page references |
| `page.zig` | Loads one page for display (stdin, `.so` redirects, format) |
| `pager.zig` | Splitting `PAGER`, piping text into it, falling back to stdout |

Tests live next to the code (`zig build test`).

## Library use

`build.zig` exports the module `dkman` (`src/root.zig`), which re-exports
`paths`, `source`, `format`, `render`, `search` and `theme`. `render.parse` returns an
`md.Document` for callers that draw the page themselves (the dkde help viewer);
`render.render` writes terminal text. `main.zig`, `pager.zig` and argument
handling stay in the program.

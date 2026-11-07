# Architecture

    source --lines--> man.zig (requests, text) --escape.zig (fonts, special characters)--> md.Node tree

| File | Role |
|---|---|
| `root.zig` | Public API: `parseMan`, `escape`, `man` |
| `escape.zig` | Splits a line of text into font runs; handles `\f`, `\(xx`, `\[uXXXX]`, `\*`, size and motion escapes |
| `man.zig` | Line by line reader for man(7): requests, paragraphs, lists, code, links |

## Mapping to the md-zig tree

| roff | Node |
|---|---|
| `.TH t s` | heading level 1 `t(s)` |
| `.SH`, `.SS` | heading level 2, 3 (argument or the next line) |
| `.PP .P .LP .HP`, blank line | ends the paragraph |
| `.TP`, `.TQ`, `.IP tag` | `deflist` with `deflist_term` and `deflist_def` (loose) |
| `.IP \(bu` | bullet `list` with `item`s |
| `.RS` / `.RE` | `block_quote` (nested up to 16 deep) |
| `.nf`/`.fi`, `.EX`/`.EE` | `code_block` |
| `.TS`/`.TE` | `code_block` of the data rows; cells separated by blanks, the tbl format section is dropped |
| `.B .I .BR .BI ...`, `\fB \fI` | `strong`, `emph` (nested for bold italic); constant width becomes `code` |
| `.UR/.UE`, `.MT/.ME` | `link` |
| `.br` | `linebreak` |

## Known losses

The tree has no exact indentation, tab stops, column layout, page headers or
footers. Indents (`.RS`, `.TP` widths) are reduced to quote levels and a fixed
definition indent. Macros defined with `.de`/`.am` are skipped, including their
uses; only `n`/`t` conditions are evaluated (`n` true, `t` false, anything else
false); `.so` is ignored; number registers are dropped.

# Architecture

    source --lines--> man.zig | mdoc.zig (requests, text) --escape.zig (fonts, special characters)--> md.Node tree

| File | Role |
|---|---|
| `root.zig` | Public API: `parseMan`, `escape`, `man` |
| `escape.zig` | Splits a line of text into font runs; handles `\f`, `\(xx`, `\[uXXXX]`, `\*`, size and motion escapes |
| `man.zig` | Line by line reader for man(7): requests, paragraphs, lists, code, links |
| `mdoc.zig` | Reader for mdoc(7): block macros, nested inline macros, lists, displays, references |

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

## mdoc mapping

| mdoc | Node |
|---|---|
| `.Dt T S` | heading level 1 `T(S)`; `.Dd`, `.Os` are skipped |
| `.Sh`, `.Ss` | heading level 2, 3 |
| `.Pp` | ends the paragraph |
| `.Bl -tag/-hang/-ohang/-inset`, `.It` | `deflist` (the `.It` line is the term) |
| `.Bl -bullet/-dash/-hyphen/-item`, `-enum` | bullet / ordered `list` |
| `.Bl -column`, `.It a Ta b` | `table` without a header row |
| `.Bd -literal/-unfilled`, `.Dl`, `.D1` | `code_block` |
| `.Fl .Cm .Ic .Sy .Nm` / `.Ar .Pa .Em .Va` / `.Li` | `strong` / `emph` / `code` |
| `.Xr n s` | text `n(s)` |
| `.Lk`, `.Mt` | `link` |
| `.Op .Dq .Sq .Pq .Bq .Aq` and the `.Oo/.Oc` pairs | bracket text around the nested content |
| `.Rs` ... `.Re` | one paragraph: authors, title, journal, date |

Nested macros follow mdoc(7): a callable macro name inside the arguments starts a
new macro, opening punctuation sticks to the next word, closing punctuation to
the previous one, `\&` makes a name literal. `.Xo`/`.Xc` join lines. In SYNOPSIS,
`.Nm`, `.Ft`, `.Fd`, `.In`, `.Vt`, `.Fn`, `.Fo` and `.Cd` start a new line.

Not supported: `.Sm`/`.Db` spacing modes, `.Bk`, `-width`/`-offset`/`-compact`,
`.Eo`/`.Ec`, `.Hf`, `.Tg`; unknown macros are ignored.

## Known losses

The tree has no exact indentation, tab stops, column layout, page headers or
footers. Indents (`.RS`, `.TP` widths) are reduced to quote levels and a fixed
definition indent. Macros defined with `.de`/`.am` are skipped, including their
uses; only `n`/`t` conditions are evaluated (`n` true, `t` false, anything else
false); `.so` is ignored; number registers are dropped.

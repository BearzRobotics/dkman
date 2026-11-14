# Verification scripts

They compare dkman's output with groff (`groff -Tutf8 -man|-mdoc`) and with man-db, and stress it.
The Python scripts and `layout.py`/`compare_mdoc.py` may still have paths for one machine at the
top; `cli.sh`, `compare_man.sh`, `compress_roundtrip.sh` and `stress.sh` take the program path as an argument.

| Script | What it does |
|---|---|
| `compare.py SEED N` (program path from `$DKMAN`, default `zig-out/bin/dkman`) | words of N random installed man pages (sections 1, 3, 5, 8) against groff; prints the worst |
| `compare_mdoc.py SEED N` | the same for a list of mdoc pages (`/tmp/mdoc_list.txt`) |
| `layout.py SEED N` | for lines that appear in both outputs, is the indent the same as groff's? |
| `cli.sh [DKMAN]` | command-line behavior on a temporary manual tree: compression formats, sections, locale, `-f`/`-k`/`-K`, exit codes (needs no installed pages) |
| `stress.sh` | renders every installed page; reports crashes and empty output |
| `compare_man.sh [N [SEED]]` | which page `man -w NAME` and `dkman -w NAME` pick, and `manpath`, for N random names (needs man-db) |
| `compress_roundtrip.sh [N [SEED]]` | N installed pages recompressed as xz/zstd/bzip2/lzma at several levels; output must equal the original's |
| `layout_diff.sh [N [SEED]]` | share of output lines identical to man-db's (groff's) for N random pages |

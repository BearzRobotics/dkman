# Verification scripts

They compare dkman's output with groff (`groff -Tutf8 -man|-mdoc`) and stress it. Paths are
absolute for one machine: edit the top of each file first.

| Script | What it does |
|---|---|
| `compare.py SEED N` | words of N random installed man pages (sections 1, 3, 5, 8) against groff; prints the worst |
| `compare_mdoc.py SEED N` | the same for a list of mdoc pages (`/tmp/mdoc_list.txt`) |
| `layout.py SEED N` | for lines that appear in both outputs, is the indent the same as groff's? |
| `cli.sh [DKMAN]` | command-line behavior on a temporary manual tree: compression formats, sections, locale, `-f`/`-k`/`-K`, exit codes (needs no installed pages) |
| `stress.sh` | renders every installed page; reports crashes and empty output |

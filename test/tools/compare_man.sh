#!/bin/bash
# Differential test against the installed man-db: which page does `man -w NAME`
# pick, and does `manpath` agree? Prints the first differences and a count.
# Usage: test/tools/compare_man.sh [N [SEED]] [path/to/dkman]
# Needs man-db's man and manpath. Uses a private page-index cache.
set -u
n=${1:-200}
seed=${2:-1}
dkman=$(realpath "${3:-zig-out/bin/dkman}")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export XDG_CACHE_HOME="$tmp"

echo "manpath: man-db '$(manpath 2>/dev/null)'  dkman '$("$dkman" -w)'"

# Names come from dkman's own index, so every one of them exists somewhere.
"$dkman" --update-index >/dev/null
names="$tmp/names"
cut -f1 "$tmp"/dkman/whatis-* | sort -u | grep -v '[^A-Za-z0-9_.+-]' |
  shuf -n "$n" --random-source=<(yes "$seed") > "$names"

diffs=0
while read -r name; do
  a=$(man -w "$name" 2>/dev/null | head -1)
  b=$("$dkman" -w "$name" 2>/dev/null | head -1)
  if [ "$a" != "$b" ]; then
    diffs=$((diffs + 1))
    [ "$diffs" -le 20 ] && echo "DIFF $name | man: ${a:-(none)} | dkman: ${b:-(none)}"
  fi
done < "$names"
echo "names=$(wc -l < "$names") differences=$diffs"
[ "$diffs" -eq 0 ]

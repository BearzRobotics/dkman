#!/bin/bash
# How close is dkman's layout to groff's (through man-db)? For N random pages,
# the share of output lines that are identical, and the worst pages.
# Usage: test/tools/layout_diff.sh [N [SEED]] [path/to/dkman]
set -u
n=${1:-40}
seed=${2:-1}
dkman=$(realpath "${3:-zig-out/bin/dkman}")
export LANG=en_US.UTF-8 MANWIDTH=80 XDG_CACHE_HOME=$(mktemp -d)
trap 'rm -rf "$XDG_CACHE_HOME"' EXIT
same=0; total=0
rows=$(mktemp)
for f in $(ls /usr/share/man/man[1-8]/*.gz | shuf -n "$n" --random-source=<(yes "$seed")); do
  a=$(man -l "$f" 2>/dev/null | sed 's/[[:space:]]*$//')
  b=$("$dkman" --no-pager --width 80 -l "$f" 2>/dev/null | sed 's/[[:space:]]*$//')
  [ -z "$a" ] && continue
  l=$(echo "$a" | wc -l)
  s=$(LC_ALL=C comm -12 <(echo "$a" | LC_ALL=C sort) <(echo "$b" | LC_ALL=C sort) | wc -l)
  total=$((total + l)); same=$((same + s))
  printf '%5d%%  %s\n' $((100 * s / l)) "$(basename "$f")" >> "$rows"
done
sort -n "$rows" | head -6
rm -f "$rows"
echo "pages=$n lines=$total identical=$same ($((100 * same / total))%)"

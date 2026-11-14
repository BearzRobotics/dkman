#!/bin/bash
# Renders every installed page; reports crashes, timeouts and empty output.
# Usage: test/tools/stress.sh [path/to/dkman]
dkman=$(realpath "${1:-zig-out/bin/dkman}")
err=$(mktemp)
trap 'rm -f "$err"' EXIT
n=0; bad=0; empty=0
for f in /usr/share/man/man*/*.gz; do
  n=$((n+1))
  out=$(timeout 10 "$dkman" --no-pager --no-color -l "$f" 2>"$err" | wc -c)
  rc=${PIPESTATUS[0]}
  if [ "$rc" -ne 0 ] && ! grep -q "not found" "$err"; then bad=$((bad+1)); echo "FAIL rc=$rc $f $(head -c 120 "$err")"; fi
  if [ "$out" -lt 40 ]; then empty=$((empty+1)); echo "EMPTY($out) $f"; fi
done
echo "pages=$n failures=$bad empty=$empty"

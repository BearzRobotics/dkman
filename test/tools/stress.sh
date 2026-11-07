#!/bin/bash
# Renders every installed page; reports crashes, timeouts and empty output.
n=0; bad=0; empty=0
for f in /usr/share/man/man*/*.gz; do
  n=$((n+1))
  out=$(timeout 10 /home/dakota/de/dkman/zig-out/bin/dkman --no-pager --no-color -l "$f" 2>/tmp/stress_err.txt | wc -c)
  rc=${PIPESTATUS[0]}
  if [ "$rc" -ne 0 ] && ! grep -q "not found" /tmp/stress_err.txt; then bad=$((bad+1)); echo "FAIL rc=$rc $f $(head -c 120 /tmp/stress_err.txt)"; fi
  if [ "$out" -lt 40 ]; then empty=$((empty+1)); echo "EMPTY($out) $f"; fi
done
echo "pages=$n failures=$bad empty=$empty"

#!/bin/bash
# Recompresses installed pages as xz, zstd, bzip2 and lzma (several levels and
# checks) and checks that dkman shows each exactly as it shows the original.
# Usage: test/tools/compress_roundtrip.sh [N [SEED]] [path/to/dkman]
# Needs xz, zstd and bzip2.
set -u
n=${1:-150}
seed=${2:-1}
dkman=$(realpath "${3:-zig-out/bin/dkman}")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export LANG=en_US.UTF-8

variants=(
  "xz:xz -c -6"
  "xz:xz -c -0"
  "xz:xz -c -9e --check=sha256"
  "xz:xz -c --check=crc32"
  "zst:zstd -qc -3"
  "zst:zstd -qc -19"
  "zst:zstd -qc --ultra -22"
  "zst:zstd -qc -1 --no-check"
  "bz2:bzip2 -c -9"
  "lzma:xz -c --format=lzma"
)

pages=$(ls /usr/share/man/man[1-8]/*.gz | shuf -n "$n" --random-source=<(yes "$seed"))
bad=0
total=0
for gz in $pages; do
  base=$(basename "$gz" .gz)
  want=$("$dkman" --no-pager --no-color -l "$gz" 2>&1 | md5sum)
  zcat "$gz" > "$tmp/plain"
  for v in "${variants[@]}"; do
    ext=${v%%:*}
    cmd=${v#*:}
    out="$tmp/$base.$ext"
    $cmd < "$tmp/plain" > "$out"
    got=$("$dkman" --no-pager --no-color -l "$out" 2>&1 | md5sum)
    total=$((total + 1))
    if [ "$got" != "$want" ]; then
      bad=$((bad + 1))
      echo "FAIL $gz as: $cmd"
    fi
  done
done
echo "pages=$n comparisons=$total failures=$bad"
[ "$bad" -eq 0 ]

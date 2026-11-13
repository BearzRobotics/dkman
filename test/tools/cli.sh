#!/bin/bash
# Command-line checks against a small manual tree built in a temporary
# directory (no installed pages needed). Usage: test/tools/cli.sh [path/to/dkman]
# Needs gzip, xz, zstd and bzip2 to make the compressed pages.
set -u
dkman=$(realpath "${1:-zig-out/bin/dkman}")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export XDG_CACHE_HOME="$tmp/cache" HOME="$tmp/home" LANG=en_US.UTF-8
unset MANPATH MANSECT MANPAGER PAGER MANWIDTH COLUMNS NO_COLOR LC_ALL LC_MESSAGES
m="$tmp/m"
mkdir -p "$m/man1" "$m/man3" "$m/man3p" "$m/de/man1"

page() { # page NAME SECTION DESCRIPTION
  printf '.TH %s %s\n.SH NAME\n%s \\- %s\n.SH DESCRIPTION\nbody of %s\n' "$1" "$2" "$1" "$3" "$1"
}
page tgz 1 "gzip page" | gzip -c > "$m/man1/tgz.1.gz"
page txz 1 "xz page" | xz -c > "$m/man1/txz.1.xz"
page tzst 1 "zstd page" | zstd -qc > "$m/man1/tzst.1.zst"
page tbz 1 "bzip2 page" | bzip2 -c > "$m/man1/tbz.1.bz2"
page tlzma 1 "lzma page" | xz --format=lzma -c > "$m/man1/tlzma.1.lzma"
page foo 1 "foo the program" > "$m/man1/foo.1"
page foo 3 "foo the library call" > "$m/man3/foo.3"
page foo 3p "foo the posix call" > "$m/man3p/foo.3p"
page foo 1 "foo auf deutsch" > "$m/de/man1/foo.1"

fail=0
check() { # check DESCRIPTION CONDITION-EXIT-CODE
  if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi
}
run() { "$dkman" -M "$m" --no-pager "$@"; }

for t in tgz txz tzst tbz tlzma; do
  run "$t" 2>&1 | grep -q "body of $t"; check "reads compressed page $t" $?
done

run foo | grep -q "body of foo"; check "plain output, no markdown markers" $([ "$(run foo | grep -c '^#\|\*\*')" -eq 0 ] && echo 0 || echo 1)
[ "$(run -w foo)" = "$m/man1/foo.1" ]; check "section order picks man1 first" $?
[ "$(run -w 3 foo)" = "$m/man3/foo.3" ]; check "section operand" $?
[ "$(run -w 'foo(3p)')" = "$m/man3p/foo.3p" ]; check "name(section)" $?
[ "$(run -s 3p:3 -w foo | head -1)" = "$m/man3p/foo.3p" ]; check "-s sets the order" $?
[ "$(run -a -w foo | wc -l)" -eq 3 ]; check "-a lists all pages" $?
[ "$(MANSECT=3 run -w foo)" = "$m/man3/foo.3" ]; check "MANSECT" $?
[ "$(run -L de -w foo)" = "$m/de/man1/foo.1" ]; check "locale directory first" $?
[ "$(LANG=de_DE.UTF-8 run -w foo)" = "$m/de/man1/foo.1" ]; check "locale from LANG" $?

run nosuch 2>/dev/null; [ $? -eq 16 ]; check "missing page exits 16" $?
run -s 3 tgz 2>&1 | grep -q "No manual entry for tgz in section 3"; check "missing in section message" $?
"$dkman" --bogus 2>/dev/null; [ $? -eq 1 ]; check "usage error exits 1" $?
"$dkman" -V | grep -q '^dkman [0-9]'; check "--version" $?
[ "$(run -w)" = "$m" ]; check "-w alone prints the manpath" $?

[ "$(run -f foo | wc -l)" -eq 3 ]; check "-f lists whatis lines" $?
run -f foo | grep -q 'foo (3) *- foo the library call'; check "-f line format" $?
run -k 'posix call' | grep -q 'foo (3p)'; check "-k searches descriptions" $?
run -k nosuchword 2>/dev/null; [ $? -eq 16 ]; check "-k without hits exits 16" $?
[ "$(run -ak foo call | wc -l)" -eq 2 ]; check "-ak needs all words" $?
run -K 'body of txz' | grep -q 'txz(1)'; check "-K searches text" $?

# The index follows the manual directories.
page tnew 1 "added later" | gzip -c > "$m/man1/tnew.1.gz"
sleep 1; touch "$m/man1"
run -f tnew 2>/dev/null | grep -q "added later"; check "index rebuilds when a directory changes" $?

run -l - < "$m/man1/foo.1" | grep -q "body of foo"; check "-l - reads standard input" $?
printf '.TH X 1\n.SH NAME\nx \\- y\n' | run -l - | head -c 1 >/dev/null; check "closed pipe is not an error" $?

[ "$(LANG=C run foo | LC_ALL=C grep -c '[^ -~]')" -eq 0 ]; check "ASCII output in the C locale" $?

[ $fail -eq 0 ] && echo "all passed" || { echo "FAILED"; exit 1; }

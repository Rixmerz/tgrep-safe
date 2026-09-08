#!/usr/bin/env bash
#
# Compares tg against ripgrep on YOUR code and reports every difference.
#
# The README's claims come from running this over a tree of 9,576 text files on an
# arm64 MacBook. There is no reason to believe them: run it and look at your own number.
#
#   ./bench/validate.sh [path]          (default: the current directory)
#
# Needs `rg` and `tg` on PATH. CRs are normalised before comparing because that
# difference is known, documented, and not the one worth hunting here.

set -uo pipefail
TARGET="${1:-.}"
# RG and TG can be pointed at specific binaries: in some environments `rg` is a shell
# function rather than an executable, and a script cannot see it.
RG="${RG:-rg}"
TG="${TG:-tg}"
command -v "$RG" >/dev/null || { echo "ripgrep missing — install it or export RG=/path/to/rg" >&2; exit 1; }
command -v "$TG" >/dev/null || { echo "tg missing — run ./install.sh or export TG=/path/to/tg" >&2; exit 1; }

pass=0; fail=0; failures=()
compare() {
  local desc="$1"; shift
  "$RG" "$@" "$TARGET" 2>/dev/null | tr -d '\r' | LC_ALL=C sort > /tmp/.v-rg
  "$TG" "$@" "$TARGET" 2>/dev/null | tr -d '\r' | LC_ALL=C sort > /tmp/.v-tg
  if cmp -s /tmp/.v-rg /tmp/.v-tg; then
    pass=$((pass+1))
  else
    fail=$((fail+1))
    failures+=("$desc  (rg=$(wc -l </tmp/.v-rg|tr -d ' ')  tg=$(wc -l </tmp/.v-tg|tr -d ' '))")
  fi
}

echo "Comparando tg contra ripgrep sobre $RUTA ..."

# Patterns. The 1- and 2-character ones are the hard test: there the trigram index
# cannot prefilter and tgrep must degrade to a full scan without losing results.
for p in 'a' 'zz' 'TODO' 'return' '\d+' '\d{2,4}' '\w+@\w+' '^import' 'export$' \
         '^\s+$' 'a.c' '(foo|bar|baz)' '\bclass\b' '[[:upper:]]{4}' '=>\s*\{' \
         'https?://\S+' '\$\{\w+\}' 'null|undefined|None' '[A-Z][a-z]+[A-Z]' \
         '0x[0-9a-fA-F]+' '\b\d{1,3}(\.\d{1,3}){3}\b' 'función|año|ñ'; do
  compare "pattern: $p" -n "$p"
done

# The flag surface: where a reimplementation actually diverges.
compare "flag -i"        -n -i 'todo'
compare "flag -w"        -n -w 'id'
compare "flag -v"        -n -v 'e'
compare "flag -x"        -n -x 'import os'
compare "flag -c"        -c 'TODO'
compare "flag -l"        -l 'return'
compare "flag -o"        -n -o '\w+@\w+'
compare "flag -m2"       -n -m 2 'import'
compare "flag -A3"       -n -A 3 'TODO'
compare "flag -C2"       -n -C 2 'TODO'
compare "flag -t py"     -n -t py 'def '
compare "flag -T py"     -n -T py 'def '
compare "flag -U"        -U -n 'class \w+\s*\{\n'
compare "flag --column"  -n --column 'TODO'
compare "flag --vimgrep" --vimgrep 'TODO'
compare "flag -M80"      -n -M 80 'import'
compare "flag --hidden"  -n --hidden 'TODO'
compare "flag -u"        -n -u 'TODO'
compare "flag --sort"    -n --sort path 'TODO'
compare "flag -e x2"     -n -e 'TODO' -e 'FIXME'
compare "flag -N"        -N 'TODO'
compare "flag --trim"    -n --trim 'TODO'

echo
echo "IDENTICAL: $pass    DIFFERENT: $fail    (total $((pass+fail)))"
if [ "$fail" -gt 0 ]; then
  echo; echo "Differences:"
  for f in "${failures[@]}"; do echo "  $f"; done
  echo
  echo "Before reporting: is it one of the three known deviations in the README?"
fi

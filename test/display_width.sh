#!/usr/bin/env bash
# Display width: `s.width()` counts terminal columns, `{s:N}` and std.fmt's
# pads fill to columns rather than to bytes, and the Unicode tables behind
# them are generated rather than typed. Both compilers must print the golden
# byte for byte.
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-display-width.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

BEANSC=${BEANSC:-./build/beansc}

run_both() {
    local name=$1
    "$BEANSC" run "test/cases/$name.b" >"$tmp/$name.interp"
    "$BEANSC" build "test/cases/$name.b" -o "$tmp/$name.native" \
        >"$tmp/$name.build" 2>&1
    "$tmp/$name.native" >"$tmp/$name.native.out"
    diff -u "test/cases/$name.out" "$tmp/$name.interp"
    diff -u "test/cases/$name.out" "$tmp/$name.native.out"
}

echo "checking every width rule names itself when it breaks"
run_both display_width_rules_ok

echo "checking measured columns and column-padded tables"
run_both display_width_ok

# A table lines up or it does not: every row of a padded column must end at
# the same byte offset in its own line. Byte padding fails this on the first
# non-ASCII row, which is the whole reason the measure exists.
echo "checking a padded column really lines up"
python3 - "test/cases/display_width_ok.out" <<'PY'
import sys

rows = [line for line in open(sys.argv[1], encoding="utf-8").read().splitlines()
        if line.startswith("|") and line.endswith("|")]
if len(rows) < 5:
    sys.exit("display width: the golden lost its padded table")
for row in rows:
    cells = row.split("|")
    if len(cells) != 4:
        sys.exit("display width: unexpected padded row %r" % row)
    # Each cell was asked for the same column count, so each must hold it.
    left, right = cells[1], cells[2]
    if len(left) != len(right):
        sys.exit("display width: %r and %r are not the same width" % (left, right))
print("  padded rows agree")
PY

echo "checking the generated tables still match the Unicode data"
if python3 -c 'import urllib.request; urllib.request.urlopen("https://www.unicode.org/Public/UCD/latest/ucd/EastAsianWidth.txt", timeout=20)' \
    >/dev/null 2>&1; then
    python3 tools/gen_width_table.py --check
else
    echo "  (skipped: unicode.org is not reachable from here)"
fi

echo "display width ok"

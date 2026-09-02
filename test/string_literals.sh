#!/usr/bin/env bash
# String literal surface (#38, #47): byte escapes `\xNN`, codepoint escapes
# `\u{...}`, and raw literals `r"..."` / `r#"..."#`. Both compilers render
# every one identically, in and out of interpolation, and the malformed
# spellings name their own mistake. The escape byte-sweep itself lives in
# crema_findings.sh; here are the raw literals and the diagnostics the new
# escapes add.
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-string-literals.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

run_both() {
    local name=$1
    ./build/beansc run "test/cases/$name.b" >"$tmp/$name.interp"
    ./build/beansc build "test/cases/$name.b" -o "$tmp/$name.native" \
        >"$tmp/$name.build" 2>&1
    "$tmp/$name.native" >"$tmp/$name.native.out"
    diff -u "test/cases/$name.out" "$tmp/$name.interp"
    diff -u "test/cases/$name.out" "$tmp/$name.native.out"
}

check_bad() {
    local file=$1
    shift
    if ./build/beansc check "test/cases/$file" >"$tmp/bad" 2>&1; then
        echo "$file unexpectedly passed" >&2
        exit 1
    fi
    local message
    for message in "$@"; do
        if ! grep -Fq "$message" "$tmp/bad"; then
            echo "$file missing message: $message" >&2
            cat "$tmp/bad" >&2
            exit 1
        fi
    done
}

# Raw literals: route templates, regexes, Windows paths, hashed bodies with
# quotes, multi-line blocks, raw inside interpolation, and reflected
# annotation arguments — every one equal to its escaped spelling, on both
# backends, byte for byte.
run_both raw_strings_ok

check_bad escape_bad.b \
    "unknown escape '\\d' — the escapes are" \
    "\\x needs exactly two hex digits, like \\x1b" \
    "\\u needs a braced codepoint of one to six hex digits" \
    "\\u{110000} is not a Unicode codepoint" \
    "\\u{d800} is not a Unicode codepoint"

check_bad raw_string_bad.b \
    'raw string never closed — it ends at "#'

check_bad interp_brace_bad.b \
    "in a string is an interpolation" \
    'for a literal brace write \{id\} or make the whole literal raw: r"..."'

# One mistake is one diagnostic, and it lands on the word rather than on the
# quote that opens the literal. The resolver's bare "unknown name" is taken
# back, not followed: `"/users/{id}/posts/{slug}"` said four things where it
# had two to say.
./build/beansc check test/cases/interp_brace_bad.b >"$tmp/brace" 2>&1 || true
if grep -q "unknown name" "$tmp/brace"; then
    echo "the brace hint should replace 'unknown name', not follow it:" >&2
    cat "$tmp/brace" >&2
    exit 1
fi
if [ "$(grep -c ': error:' "$tmp/brace")" != "1" ]; then
    echo "one unresolvable piece should be one diagnostic:" >&2
    cat "$tmp/brace" >&2
    exit 1
fi
grep -q ':6:25: error:' "$tmp/brace" ||
    { echo "the hint should point at the name, not at the literal:" >&2
      cat "$tmp/brace" >&2; exit 1; }

# The lexer and every walker re-reading a string token find raw literals in
# the same places: `r` after an identifier byte is not a prefix, inside an
# interpolation as much as at the top level.
check_bad raw_open_bad.b \
    "string not closed before end of line"
./build/beansc check test/cases/raw_open_bad.b >"$tmp/rawopen" 2>&1 || true
if grep -q "in string piece" "$tmp/rawopen"; then
    echo "the lexer and the checker split this token differently:" >&2
    cat "$tmp/rawopen" >&2
    exit 1
fi

echo "ok string literals: raw forms and byte/codepoint escapes, both backends"

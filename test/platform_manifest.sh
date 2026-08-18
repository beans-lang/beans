#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

manifest=targets/support.tsv
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-platforms.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

[[ -f "$manifest" ]] || {
    echo "missing $manifest" >&2
    exit 1
}

echo "checking the Rust-parity target manifest"

awk -F '\t' '
BEGIN { good = 1 }
/^#/ || NF == 0 { next }
{
    rows++
    if (NF != 8) {
        printf "%s:%d: expected 8 tab-separated fields, got %d\n", FILENAME, NR, NF > "/dev/stderr"
        good = 0
        next
    }
    if ($2 != "1" && $2 != "2") {
        printf "%s:%d: bad Rust tier %s\n", FILENAME, NR, $2 > "/dev/stderr"
        good = 0
    }
    tier[$2]++
    if (seen_rust[$1]++) {
        printf "%s:%d: duplicate Rust target %s\n", FILENAME, NR, $1 > "/dev/stderr"
        good = 0
    }
    for (field = 4; field <= 7; field++) {
        if ($field != "pass" && $field != "missing") {
            printf "%s:%d: field %d must be pass or missing\n", FILENAME, NR, field > "/dev/stderr"
            good = 0
        }
    }
    if ($3 == "-") {
        planned++
        if ($4 != "missing" || $5 != "missing" || $6 != "missing" || $7 != "missing") {
            printf "%s:%d: an unregistered target cannot have a passing gate\n", FILENAME, NR > "/dev/stderr"
            good = 0
        }
    } else {
        registered++
        if (seen_beans[$3]++) {
            printf "%s:%d: duplicate Beans target %s\n", FILENAME, NR, $3 > "/dev/stderr"
            good = 0
        }
        if ($4 != "pass") {
            printf "%s:%d: a registered target needs a real program execution gate\n", FILENAME, NR > "/dev/stderr"
            good = 0
        }
        if ($4 == "pass" && $5 == "pass" && $6 == "pass" && $7 == "pass") complete++
        else partial++
    }
    if ($5 == "pass" && $4 != "pass") {
        printf "%s:%d: compiler pass needs program pass\n", FILENAME, NR > "/dev/stderr"
        good = 0
    }
    if ($6 == "pass" && $5 != "pass") {
        printf "%s:%d: bootstrap pass needs compiler pass\n", FILENAME, NR > "/dev/stderr"
        good = 0
    }
    if ($7 == "pass" && $6 != "pass") {
        printf "%s:%d: archive pass needs bootstrap pass\n", FILENAME, NR > "/dev/stderr"
        good = 0
    }
    if ($8 == "-" && !($4 == "pass" && $5 == "pass" && $6 == "pass" && $7 == "pass")) {
        printf "%s:%d: incomplete target has no blocker\n", FILENAME, NR > "/dev/stderr"
        good = 0
    }
}
END {
    if (rows != 25 || tier[1] != 7 || tier[2] != 18) {
        printf "expected 25 Rust hosts (7 tier 1, 18 tier 2); got %d (%d, %d)\n", rows, tier[1], tier[2] > "/dev/stderr"
        good = 0
    }
    printf "%d\t%d\t%d\n", complete, partial, planned
    if (!good) exit 1
}
' "$manifest" >"$tmp/counts"

compiler_targets() {
    "$1" target definitely-not-a-target 2>&1 || true
}

for compiler in ./build/beansc; do
    [[ -x "$compiler" ]] || {
        echo "$compiler is not built" >&2
        exit 1
    }
    compiler_targets "$compiler" |
        sed -n 's/.*supported targets are //p' |
        tr ',' '\n' | sed 's/^ *//' | sort >"$tmp/$(basename "$compiler").all"
    [[ -s "$tmp/$(basename "$compiler").all" ]] || {
        echo "could not read targets from $compiler" >&2
        exit 1
    }
done

while read -r triple; do
    os=$(./build/beansc target "$triple" | awk '/^os / { print $2 }')
    if [[ "$os" == linux || "$os" == windows ]]; then
        printf '%s\n' "$triple"
    fi
done <"$tmp/beansc.all" | sort >"$tmp/compiler-platforms"

awk -F '\t' '!/^#/ && NF && $3 != "-" { print $3 }' "$manifest" |
    sort >"$tmp/manifest-platforms"

if ! diff -u "$tmp/manifest-platforms" "$tmp/compiler-platforms"; then
    echo "$manifest and the compiler disagree about registered Windows/Linux targets" >&2
    exit 1
fi

IFS=$'\t' read -r complete partial planned <"$tmp/counts"
echo "  complete $complete / 25"
echo "  partial  $partial / 25"
echo "  missing  $planned / 25"
echo "ok platform manifest: both compilers and the Rust-parity scope agree"

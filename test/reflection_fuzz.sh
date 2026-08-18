#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

seeds=${REFLECT_FUZZ_SEEDS:-8}
cases=${REFLECT_FUZZ_CASES:-20}
case "$seeds:$cases" in
    *[!0-9:]*) echo "reflection fuzz counts must be whole numbers" >&2; exit 2 ;;
esac
if [[ "$seeds" -lt 1 || "$cases" -lt 1 ]]; then
    echo "reflection fuzz counts must be positive" >&2
    exit 2
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-reflect-fuzz.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

for ((seed = 1; seed <= seeds; seed++)); do
    source_file="$tmp/seed-$seed.b"
    python3 tools/reflection_fuzz.py \
        --seed "$seed" --cases "$cases" --output "$source_file"

    # The two backends must agree on generated reflection programs. This
    # once compared four ways, the stage-0 bootstrap's interpreter and
    # native output included; with the bootstrap gone the remaining pair is
    # still a real differential, because the tree interpreter and the LLVM
    # emitter are separate implementations of the same semantics. Generated
    # sources reach shapes the fixed cases do not.
    ./build/beansc run "$source_file" >"$tmp/interp-$seed.out"

    ./build/beansc build "$source_file" -o "$tmp/native-$seed" >/dev/null
    "$tmp/native-$seed" >"$tmp/native-$seed.out"
    cmp "$tmp/interp-$seed.out" "$tmp/native-$seed.out"

    ./build/beansc build --release "$source_file" \
        -o "$tmp/release-$seed" >/dev/null
    "$tmp/release-$seed" >"$tmp/release-$seed.out"
    cmp "$tmp/interp-$seed.out" "$tmp/release-$seed.out"
done

echo "ok reflection fuzz, interpreter vs native ($seeds seeds, $cases actions each)"

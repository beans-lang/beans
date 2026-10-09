#!/usr/bin/env bash
# A Linux build past the chunk threshold is split, and every chunk states the
# module's PIC and PIE levels (CD-22).
#
# A Linux module carries `!llvm.module.flags` with both levels: an .ll file
# handed to Clang gets no distro-default PIE levels of its own, and on ppc32
# they choose the secure-PLT code model. The emitter once kept them in the
# same list as the `--debug` line table, and `chunk_modules` refuses to split
# a module with a line table, so no Linux build ever took the chunked backend.
# A chunk is compiled on its own, so a chunk without the flags is compiled for
# a different code model than the module it came from.
#
# This reads the chunk modules the driver hands Clang. The stand-in Clang
# keeps each one and refuses to compile it, so no cross toolchain is needed and
# the build stops there; what Clang would make of them is the job of the Linux
# gates (`test/sanitize.sh` links real chunk objects, `test/linux_arch.sh`
# runs ppc32).
set -euo pipefail

cd "$(dirname "$0")/.."
bin=${BEANSC:-./build/beansc}
work=$(mktemp -d)
stem="chunk_module_flags_$$"
cleanup() {
    rm -rf "$work"
    rm -f build/beans_chunk."$stem".* build/"$stem".* "build/${stem}_ffi.c"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "checking that Linux chunk modules carry the PIC and PIE levels (CD-22)"

# The threshold is 4 MiB of IR (native_chunk_count in src/driver.b); 512
# unique 8 KiB literals cross it.
cat >"$work/$stem.b" <<'BEANS'
package main

import std.io

fn main() {
    io.println("chunked")
}
BEANS
awk 'BEGIN {
    padding = ""
    for (j = 0; j < 8192; j++) padding = padding "x"
    for (i = 0; i < 512; i++)
        printf "fn chunk_flags_padding_%d() -> string { return r\"%d%s\" }\n", i, i, padding
}' >>"$work/$stem.b"

cat >"$work/clang" <<'SCRIPT'
#!/usr/bin/env bash
for argument in "$@"; do
    case "$argument" in
        *beans_chunk.*.ll)
            cp "$argument" "$CHUNK_FLAGS_KEEP/"
            echo "chunk kept, not compiled" >&2
            exit 1 ;;
    esac
done
exec clang "$@"
SCRIPT
chmod +x "$work/clang"

# x86-64 and AArch64 are the Linux hosts; ppc32 is the target whose code the
# levels change.
for target in x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu \
        powerpc-unknown-linux-gnu; do
    keep="$work/$target"
    mkdir -p "$keep"
    set +e
    CHUNK_FLAGS_KEEP="$keep" BEANS_BUILD_JOBS=8 \
        "$bin" build --target "$target" --cc "$work/clang" \
        "$work/$stem.b" -o "$work/$stem.$target" >"$work/$target.log" 2>&1
    set -e
    [[ $(wc -c <"build/$stem.ll") -ge 4194304 ]] ||
        fail "the probe no longer crosses the 4 MiB chunk threshold"
    grep -q '"PIC Level", i32 2' "build/$stem.ll" ||
        fail "$target: the module states no PIC level"
    chunks=$(find "$keep" -name '*.ll' | wc -l | tr -d ' ')
    if [[ "$chunks" -lt 2 ]]; then
        cat "$work/$target.log" >&2
        fail "$target: the build handed Clang $chunks chunk modules; a Linux" \
             "module past the threshold must be split"
    fi
    for chunk in "$keep"/*.ll; do
        name=$(basename "$chunk")
        flags=$(grep '^!llvm\.module\.flags = ' "$chunk" || true)
        [[ -n "$flags" ]] || fail "$target: $name has no !llvm.module.flags"
        found=""
        for node in $(printf '%s\n' "$flags" | grep -oE '![0-9]+'); do
            definition=$(grep "^$node = " "$chunk" || true)
            [[ -n "$definition" ]] ||
                fail "$target: $name names $node in its flags but never defines it"
            found="$found$definition"$'\n'
        done
        for level in "PIC Level" "PIE Level"; do
            printf '%s' "$found" | grep -qF "!\"$level\", i32 2" ||
                fail "$target: $name does not state its $level"
        done
    done
    echo "  ok: $target, $chunks chunk modules, each with both levels"
    rm -f build/beans_chunk."$stem".*
done

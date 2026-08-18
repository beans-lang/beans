#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$root"

case "$(uname -s):$(uname -m)" in
    Linux:x86_64|Linux:aarch64|Darwin:arm64) ;;
    *)
        echo "tier-1 C ABI needs native Linux x86-64, Linux arm64, or macOS arm64" >&2
        exit 1
        ;;
esac

tests=(
    test/c_layout_structs.sh
    test/c_layout_unions.sh
    test/c_layout_c_abi.sh
    test/c_wide_args.sh
    test/c_callbacks.sh
    test/c_opaque.sh
    test/c_globals.sh
    test/stack_pointer.sh
    test/link_manifest.sh
    test/library_output.sh
    test/bindgen.sh
    test/stored_callbacks.sh
)

for compiler in "$root/build/beansc"; do
    test -x "$compiler"
    echo "tier-1 C ABI with $(basename "$compiler")"
    for test_script in "${tests[@]}"; do
        BEANSC="$compiler" BEANS_SANITIZE_CALLBACKS=1 \
            bash "$test_script"
    done
done

echo "ok tier-1 C ABI: stage 0 and self-hosted compiler"

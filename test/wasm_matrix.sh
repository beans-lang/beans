#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
compiler=${BEANSC:-./build/beansc}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-wasm-matrix.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

passed=0
while IFS=$'\t' read -r feature source mode expected; do
    [[ -z "$feature" || "$feature" == \#* ]] && continue
    case "$mode" in
        ir)
            if ! "$compiler" build --target wasm32-wasip1 \
                    --runtime freestanding --emit ir "$source" \
                    >"$tmp/output" 2>&1; then
                echo "WASM feature '$feature' did not reach LLVM IR: $source" >&2
                sed -n '1,40p' "$tmp/output" >&2
                exit 1
            fi
            ;;
        library)
            if ! "$compiler" build --target wasm32-wasip1 \
                    --runtime freestanding --emit ir "$source" \
                    >"$tmp/output" 2>&1; then
                echo "WASM library '$feature' did not reach LLVM IR: $source" >&2
                sed -n '1,40p' "$tmp/output" >&2
                exit 1
            fi
            ;;
        browser-library)
            if ! "$compiler" build --target wasm32-unknown-unknown \
                    --runtime freestanding --emit ir "$source" \
                    >"$tmp/output" 2>&1; then
                echo "browser WASM library '$feature' did not reach LLVM IR: $source" >&2
                sed -n '1,40p' "$tmp/output" >&2
                exit 1
            fi
            ;;
        simd)
            if ! "$compiler" build --target wasm32-wasip1 \
                    --features +simd128 --runtime freestanding --emit ir \
                    "$source" >"$tmp/output" 2>&1; then
                echo "WASM SIMD feature '$feature' did not reach LLVM IR: $source" >&2
                sed -n '1,40p' "$tmp/output" >&2
                exit 1
            fi
            ;;
        wasi)
            if ! "$compiler" build --target wasm32-wasip1 \
                    --runtime minimal --emit ir "$source" \
                    >"$tmp/output" 2>&1; then
                echo "WASI feature '$feature' did not reach LLVM IR: $source" >&2
                sed -n '1,40p' "$tmp/output" >&2
                exit 1
            fi
            ;;
        wasi-full)
            if ! "$compiler" build --target wasm32-wasip1 \
                    --runtime full --emit ir "$source" \
                    >"$tmp/output" 2>&1; then
                echo "full WASI feature '$feature' did not reach LLVM IR: $source" >&2
                sed -n '1,40p' "$tmp/output" >&2
                exit 1
            fi
            ;;
        reject)
            if "$compiler" check --target wasm32-wasip1 --runtime full "$source" \
                    >"$tmp/output" 2>&1; then
                echo "WASM feature '$feature' was accepted but is marked reject: $source" >&2
                exit 1
            fi
            if ! grep -qF -- "$expected" "$tmp/output"; then
                echo "WASM feature '$feature' did not report '$expected':" >&2
                sed -n '1,20p' "$tmp/output" >&2
                exit 1
            fi
            ;;
        *)
            echo "unknown WASM feature mode '$mode' for '$feature'" >&2
            exit 1
            ;;
    esac
    passed=$((passed + 1))
done < test/wasm_features.tsv

[[ "$passed" -gt 0 ]] || {
    echo "the WASM feature matrix is empty" >&2
    exit 1
}
echo "ok WASM feature matrix: $passed core, WASI, or explicitly rejected features"

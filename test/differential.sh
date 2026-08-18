#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-diff.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

failed=0
refused=0
ran=0
for file in examples/*.b examples/shop/main.b; do
    name=$(basename "$file" .b)
    bin="$tmp/${name}_native"
    if ! ./build/beansc check "$file" >"$tmp/${name}.check" 2>&1; then
        # Some examples exercise a target feature on purpose. They are not
        # portable to targets without that feature, but the compiler must
        # refuse them cleanly at check time rather than failing in codegen.
        if grep -Eq \
            "is not a feature .* has;|is not .* assembly; this target allows|needs [0-9]+-bit atomics, which .* does not support|decimal is not available in the runtime for|with the selected features supports at most|is wider than .* supports with the selected features|MMap is not available on target|runtime does not have .*needs at least" \
            "$tmp/${name}.check"; then
            echo "refused $file (target capability)"
            refused=$((refused + 1))
            continue
        fi
        echo "check failed: $file" >&2
        sed -n '1,80p' "$tmp/${name}.check" >&2
        failed=1
        continue
    fi
    if ! ./build/beansc build "$file" -o "$bin" >"$tmp/${name}.build" 2>&1; then
        echo "build failed: $file" >&2
        sed -n '1,80p' "$tmp/${name}.build" >&2
        failed=1
        continue
    fi

    # Some native hosts cannot safely load the JSON/XML C bridges through the
    # interpreter. On ARM1176 that bridge path traps with an illegal instruction
    # even though the native programs work. The shipped native binaries are the
    # path users run, so let that gate compare their output with checked-in
    # goldens instead of running the host bridge.
    if [[ "${BEANS_DIFFERENTIAL_ENCODING_GOLDENS:-0}" == 1 ]]; then
        case "$name" in
            zero_copy_json|zero_copy_xml)
                set +e
                "$bin" >"$tmp/${name}.native" 2>&1
                native_status=$?
                set -e
                ran=$((ran + 1))
                if [[ "$native_status" -ne 0 ]] || \
                    ! cmp -s "test/cases/${name}.out" "$tmp/${name}.native"; then
                    echo "golden failure: $file (native=$native_status)" >&2
                    diff -u "test/cases/${name}.out" "$tmp/${name}.native" \
                        | sed -n '1,120p' >&2 || true
                    failed=1
                else
                    echo "ok $file (native golden)"
                fi
                continue
                ;;
        esac
    fi

    set +e
    ./build/beansc run "$file" >"$tmp/${name}.interp" 2>&1
    interp_status=$?
    "$bin" >"$tmp/${name}.native" 2>&1
    native_status=$?
    set -e
    ran=$((ran + 1))

    if [[ "$interp_status" -ne "$native_status" ]] || \
        ! cmp -s "$tmp/${name}.interp" "$tmp/${name}.native"; then
        echo "differential failure: $file (run=$interp_status native=$native_status)" >&2
        diff -u "$tmp/${name}.interp" "$tmp/${name}.native" | sed -n '1,120p' >&2 || true
        failed=1
    else
        echo "ok $file"
    fi
done

if [[ "$refused" -ne 0 ]]; then
    echo "target capability refusals: $refused"
fi
if [[ "$ran" -lt 40 ]]; then
    echo "differential gate ran only $ran examples; expected at least 40" >&2
    failed=1
fi

exit "$failed"

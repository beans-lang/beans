#!/usr/bin/env bash
# The Windows half of the native differential gate: execute a bundle produced
# by test/windows_native_stage.sh and hold every binary to the interpreter's
# answer — byte-identical output, exit codes included. Needs nothing but bash,
# cmp and grep (Git Bash on a GitHub windows runner has all three); the point
# is that it runs on genuine Windows, where Wine's sins cannot cover for us.
set -uo pipefail

BUNDLE=${1:-build/windows_native}
# The architecture the bundle claims to be. Given, it is asserted against the
# PE header of every binary before anything runs, so a bundle staged for the
# wrong target cannot quietly pass by never being executed.
WANT_ARCH=${2:-${WANT_ARCH:-}}

if [[ ! -f "$BUNDLE/manifest.tsv" ]]; then
    echo "FAIL: no manifest at $BUNDLE/manifest.tsv — run test/windows_native_stage.sh first" >&2
    exit 1
fi

fails=0
ran=0

# The PE Machine field, straight out of the header: offset 0x3c holds the PE
# signature offset, and the two bytes after "PE\0\0" are the machine. Read with
# od so this still needs nothing but the tools Git Bash already ships.
pe_machine() { # <exe>
    local at
    at=$(od -An -tu4 -j 60 -N 4 "$1" 2>/dev/null | tr -d ' ')
    [[ -z "$at" ]] && { echo "none"; return; }
    case "$(od -An -tx1 -j "$((at + 4))" -N 2 "$1" 2>/dev/null | tr -d ' ')" in
        6486) echo "x86_64" ;;
        4c01) echo "i686" ;;
        64aa) echo "aarch64" ;;
        *) echo "unknown" ;;
    esac
}

if [[ -n "$WANT_ARCH" ]]; then
    mismatch=0
    for exe in "$BUNDLE"/*.exe; do
        [[ -e "$exe" ]] || continue
        got=$(pe_machine "$exe")
        if [[ "$got" != "$WANT_ARCH" ]]; then
            echo "FAIL: $(basename "$exe") is a $got binary; the bundle claims $WANT_ARCH" >&2
            mismatch=$((mismatch + 1))
        fi
    done
    if [[ $mismatch -ne 0 ]]; then
        echo "windows native gate: $mismatch binaries have the wrong PE machine" >&2
        exit 1
    fi
    echo "every staged binary carries PE machine $WANT_ARCH"
fi
while IFS=$'\t' read -r stem expected_code; do
    [[ -z "$stem" ]] && continue
    # Strip a trailing CR: the manifest is written on the staging host, and a
    # Windows checkout that has not honoured .gitattributes would otherwise make
    # the exit-code column a string that never compares equal.
    expected_code=${expected_code%$'\r'}
    "$BUNDLE/$stem.exe" > "$BUNDLE/$stem.actual" 2>&1
    code=$?
    # 0xc000007b / 3221225595 is STATUS_INVALID_IMAGE_FORMAT: the binary is for
    # another architecture and this machine cannot run it. That is a failure of
    # the gate, never a skip — the whole point is that these execute here.
    if [[ $code -eq 3221225595 || $code -eq 3221225781 ]]; then
        echo "FAIL: $stem.exe did not load (status $code) — wrong architecture for this machine" >&2
        fails=$((fails + 1))
        continue
    fi
    ran=$((ran + 1))
    if [[ "$code" != "$expected_code" ]]; then
        echo "FAIL: $stem.exe exited $code; the interpreter exited $expected_code" >&2
        fails=$((fails + 1))
    fi
    if ! cmp -s "$BUNDLE/$stem.expected" "$BUNDLE/$stem.actual"; then
        echo "FAIL: $stem.exe output differs from the interpreter's" >&2
        diff "$BUNDLE/$stem.expected" "$BUNDLE/$stem.actual" | head -15 >&2
        fails=$((fails + 1))
    fi
done < "$BUNDLE/manifest.tsv"

# target_info must report the Windows target from a genuinely running binary.
if [[ -f "$BUNDLE/target_info.exe" ]]; then
    "$BUNDLE/target_info.exe" > "$BUNDLE/target_info.actual" 2>&1
    grep -q "windows" "$BUNDLE/target_info.actual" || {
        echo "FAIL: target_info.exe does not report os windows" >&2
        fails=$((fails + 1))
    }
    grep -q "coff" "$BUNDLE/target_info.actual" || {
        echo "FAIL: target_info.exe does not report object_format coff" >&2
        fails=$((fails + 1))
    }
else
    echo "FAIL: bundle has no target_info.exe" >&2
    fails=$((fails + 1))
fi

# The positive golden for the layout facts the cross-machine diff cannot judge:
# a running binary must report *its own* target's pointer width. On a 32-bit
# target that is 4, and a silent regression to the host's 8 is precisely the bug
# shape that once made `deinit` never run on a 32-bit board.
if [[ -f "$BUNDLE/pointer_size" && -f "$BUNDLE/c_layout_structs.exe" ]]; then
    want=$(tr -d ' \r\n' < "$BUNDLE/pointer_size")
    "$BUNDLE/c_layout_structs.exe" > "$BUNDLE/c_layout_structs.actual" 2>&1
    got=$(sed -n 's/^pointer pointer \([0-9]*\) \([0-9]*\) .*/\1 \2/p' \
        "$BUNDLE/c_layout_structs.actual")
    if [[ "$got" != "$want $want" ]]; then
        echo "FAIL: c_layout_structs.exe reports pointer size/align [$got]; this target's is [$want $want]" >&2
        fails=$((fails + 1))
    else
        echo "pointer size/align on the running binary: $got (the target's, not the host's)"
    fi
fi

# A gate that ran nothing must not read as green. The floor tracks the staging
# script's per-target floor: i686 stages slightly fewer because its assembly
# surface is smaller and one layout case uses the positive golden above.
case "$WANT_ARCH" in
    i686) floor=49 ;;
    "") floor=30 ;;
    *) floor=54 ;;
esac
if [[ $ran -lt $floor ]]; then
    echo "FAIL: only $ran examples ran; the floor for ${WANT_ARCH:-this bundle} is $floor" >&2
    fails=$((fails + 1))
fi

if [[ $fails -ne 0 ]]; then
    echo "windows native gate: $fails failure(s) across $ran examples" >&2
    exit 1
fi

# The public TlsListener must also use the portable SChannel byte pump on
# Windows. This is separate from the accepted-TcpStream test below so the
# listener's port-0, timeout, SNI, and ALPN contract cannot regress unseen.
export BEANS_TLS_DEBUG=1
if [[ -x "$BUNDLE/tls_listener_server.exe" &&
      -x "$BUNDLE/tls_server_client.exe" ]]; then
    "$BUNDLE/tls_listener_server.exe" \
        "$BUNDLE/tls_certs/valid.crt" "$BUNDLE/tls_certs/valid.key" \
        "$BUNDLE/tls_certs/sni.crt" "$BUNDLE/tls_certs/sni.key" \
        > "$BUNDLE/tls_listener_server.out" \
        2> "$BUNDLE/tls_listener_server.err" &
    tls_listener_pid=$!
    tls_listener_port=""
    for _ in $(seq 1 100); do
        tr -d '\r' < "$BUNDLE/tls_listener_server.err" \
            > "$BUNDLE/tls_listener_server.err.clean"
        tls_listener_port=$(sed -n 's/^listening //p' \
            "$BUNDLE/tls_listener_server.err.clean" | head -1)
        [[ -n "$tls_listener_port" ]] && break
        kill -0 "$tls_listener_pid" 2>/dev/null || break
        sleep 0.1
    done
    if [[ -z "$tls_listener_port" ]]; then
        echo "FAIL: SChannel TlsListener did not start" >&2
        cat "$BUNDLE/tls_listener_server.err.clean" >&2
        fails=$((fails + 1))
    else
        "$BUNDLE/tls_server_client.exe" "$tls_listener_port" \
            "$BUNDLE/tls_certs/ca.crt" sni.localhost h2 h2 \
            > "$BUNDLE/tls_listener_client.out" 2>&1
        tr -d '\r' < "$BUNDLE/tls_listener_client.out" \
            > "$BUNDLE/tls_listener_client.clean"
        grep -q '^tls server client true$' \
            "$BUNDLE/tls_listener_client.clean" || {
                echo "FAIL: SChannel TlsListener SNI client failed" >&2
                cat "$BUNDLE/tls_listener_client.clean" >&2
                fails=$((fails + 1))
            }
        "$BUNDLE/tls_server_client.exe" "$tls_listener_port" \
            "$BUNDLE/tls_certs/ca.crt" localhost http/1.1 http/1.1 \
            > "$BUNDLE/tls_listener_client.out" 2>&1
        tr -d '\r' < "$BUNDLE/tls_listener_client.out" \
            > "$BUNDLE/tls_listener_client.clean"
        grep -q '^tls server client true$' \
            "$BUNDLE/tls_listener_client.clean" || {
                echo "FAIL: SChannel TlsListener default client failed" >&2
                cat "$BUNDLE/tls_listener_client.clean" >&2
                fails=$((fails + 1))
            }
    fi
    wait "$tls_listener_pid"
    tls_listener_code=$?
    tr -d '\r' < "$BUNDLE/tls_listener_server.out" \
        > "$BUNDLE/tls_listener_server.clean"
    if [[ $tls_listener_code -ne 0 ]] ||
       ! cmp -s "$BUNDLE/tls_listener_server.clean" \
           "$BUNDLE/tls_listener_server.expected"; then
        echo "FAIL: SChannel TlsListener server failed" >&2
        cat "$BUNDLE/tls_listener_server.err.clean" \
            "$BUNDLE/tls_listener_server.clean" >&2
        fails=$((fails + 1))
    else
        echo "SChannel TlsListener: port 0, timeout, SNI, and ALPN passed"
    fi
fi

# The staged TLS pair uses SChannel at both ends. It proves PEM, PKCS#12,
# named SNI selection, server ALPN, encrypted records, and close-notify on the
# actual Windows kernel rather than Wine or a cross compiler.
if [[ -x "$BUNDLE/tls_server.exe" && -x "$BUNDLE/tls_server_client.exe" ]]; then
    case "$WANT_ARCH" in
        i686) tls_port=15441 ;;
        aarch64) tls_port=15442 ;;
        *) tls_port=15443 ;;
    esac
    "$BUNDLE/tls_server.exe" \
        "$BUNDLE/tls_certs/valid.crt" "$BUNDLE/tls_certs/valid.key" \
        "$BUNDLE/tls_certs/sni.crt" "$BUNDLE/tls_certs/sni.key" \
        "$BUNDLE/tls_server.p12" "$BUNDLE/tls_certs/ca.crt" "$tls_port" \
        "h2,http/1.1" h2 http/1.1 \
        > "$BUNDLE/tls_server.out" 2> "$BUNDLE/tls_server.err" &
    tls_pid=$!
    for _ in $(seq 1 100); do
        grep -q '^listening' "$BUNDLE/tls_server.err" 2>/dev/null && break
        kill -0 "$tls_pid" 2>/dev/null || break
        sleep 0.1
    done
    "$BUNDLE/tls_server_client.exe" "$tls_port" \
        "$BUNDLE/tls_certs/ca.crt" sni.localhost h2 h2 \
        > "$BUNDLE/tls_client.out" 2>&1
    tr -d '\r' < "$BUNDLE/tls_client.out" > "$BUNDLE/tls_client.clean"
    if ! grep -q '^tls server client true$' "$BUNDLE/tls_client.clean"; then
        echo "FAIL: SChannel PEM/SNI client failed" >&2
        cat "$BUNDLE/tls_server.err" "$BUNDLE/tls_client.clean" >&2
        fails=$((fails + 1))
    fi
    "$BUNDLE/tls_server_client.exe" "$tls_port" \
        "$BUNDLE/tls_certs/ca.crt" localhost http/1.1 http/1.1 \
        > "$BUNDLE/tls_client.out" 2>&1
    tr -d '\r' < "$BUNDLE/tls_client.out" > "$BUNDLE/tls_client.clean"
    if ! grep -q '^tls server client true$' "$BUNDLE/tls_client.clean"; then
        echo "FAIL: SChannel PKCS#12 client failed" >&2
        cat "$BUNDLE/tls_server.err" "$BUNDLE/tls_client.clean" >&2
        fails=$((fails + 1))
    fi
    wait "$tls_pid"
    tls_code=$?
    tr -d '\r' < "$BUNDLE/tls_server.out" > "$BUNDLE/tls_server.clean"
    if [[ $tls_code -ne 0 ]] ||
       ! grep -q '^tls server pem sni true$' "$BUNDLE/tls_server.clean" ||
       ! grep -q '^tls server pkcs12 true$' "$BUNDLE/tls_server.clean"; then
        echo "FAIL: SChannel server failed" >&2
        cat "$BUNDLE/tls_server.err" "$BUNDLE/tls_server.clean" >&2
        fails=$((fails + 1))
    else
        echo "SChannel client/server: PEM, PKCS#12, SNI and ALPN passed"
    fi
else
    echo "FAIL: the Windows bundle has no SChannel test pair" >&2
    fails=$((fails + 1))
fi

if [[ -x "$BUNDLE/tls_fuzz.exe" && -x "$BUNDLE/tls_fuzz_server.exe" ]]; then
    fuzz_port=$((tls_port + 10))
    "$BUNDLE/tls_fuzz_server.exe" \
        "$BUNDLE/tls_certs/valid.crt" "$BUNDLE/tls_certs/valid.key" \
        "$fuzz_port" 2 \
        > "$BUNDLE/tls_fuzz_server.out" \
        2> "$BUNDLE/tls_fuzz_server.err" &
    fuzz_pid=$!
    for _ in $(seq 1 100); do
        grep -q '^listening' "$BUNDLE/tls_fuzz_server.err" 2>/dev/null && break
        kill -0 "$fuzz_pid" 2>/dev/null || break
        sleep 0.1
    done
    "$BUNDLE/tls_fuzz.exe" "$BUNDLE/tls_certs/ca.crt" localhost \
        "$fuzz_port" 1 2 > "$BUNDLE/tls_fuzz.out" 2>&1
    fuzz_code=$?
    wait "$fuzz_pid"
    fuzz_server_code=$?
    tr -d '\r' < "$BUNDLE/tls_fuzz.out" > "$BUNDLE/tls_fuzz.clean"
    tr -d '\r' < "$BUNDLE/tls_fuzz_server.out" \
        > "$BUNDLE/tls_fuzz_server.clean"
    if [[ $fuzz_code -ne 0 || $fuzz_server_code -ne 0 ]] ||
       ! grep -q '^ok tls_fuzz seed=1 rounds=2$' \
           "$BUNDLE/tls_fuzz.clean" ||
       ! grep -q '^tls fuzz server true$' \
           "$BUNDLE/tls_fuzz_server.clean"; then
        echo "FAIL: SChannel partial-IO contract failed" >&2
        cat "$BUNDLE/tls_fuzz_server.err" "$BUNDLE/tls_fuzz.clean" \
            "$BUNDLE/tls_fuzz_server.clean" >&2
        fails=$((fails + 1))
    else
        echo "SChannel partial-IO fragmentation passed"
    fi
else
    echo "FAIL: the Windows bundle has no SChannel partial-IO pair" >&2
    fails=$((fails + 1))
fi

if [[ $fails -ne 0 ]]; then
    echo "windows native gate: $fails failure(s) across $ran examples" >&2
    exit 1
fi
# The exact machine, OS, and staged toolchain this run proved, for the
# record: the oracle-checked differential corpus rows (dfuzz_case_*) executed
# on this architecture, not merely compiled for it. A bundle with no corpus
# rows fails here — a compile-only pass is not this gate's claim.
staged_triple=""
[[ -f "$BUNDLE/triple" ]] && staged_triple=$(tr -d ' \r\n' < "$BUNDLE/triple")
staged_toolchain=""
[[ -f "$BUNDLE/toolchain" ]] && \
    staged_toolchain=$(tr -d '\r' < "$BUNDLE/toolchain" | paste -sd ';' -)
corpus_meta=""
[[ -f "$BUNDLE/corpus_meta" ]] && corpus_meta=$(tr -d '\r\n' < "$BUNDLE/corpus_meta")
corpus_ran=$(grep -c '^dfuzz_case_' "$BUNDLE/manifest.tsv" || true)
if [[ "$corpus_ran" -eq 0 ]]; then
    echo "FAIL: the bundle carries no differential corpus rows; stage with python3 available" >&2
    exit 1
fi
os_ver=$( (cmd.exe /c ver 2>/dev/null || uname -sr) | tr -d '\r' | grep -v '^$' | head -1 )
echo "ok windows native gate: $ran examples byte-identical on real Windows"
echo "   os ${os_ver:-unknown}, machine $(uname -m 2>/dev/null || echo unknown), execution native (PE machine asserted before any run)"
echo "   target ${staged_triple:-unknown}, staged by ${staged_toolchain:-unknown}"
echo "   corpus ${corpus_meta:-unknown}: ${corpus_ran} oracle-checked cases executed"

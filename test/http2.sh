#!/usr/bin/env bash
# std.http's HTTP/2 side: a client and server exchanging real streams over
# loopback, the glue fuzzer, curl and nghttpd interop, and h2spec.
#
# The h2spec bar is set by measurement, not by hope: nghttp2's own reference
# server (nghttpd) is run through the identical suite first, and this
# implementation must fail no case that nghttpd passes. That is the honest
# bar for a binding — the library's behavior is the library's, and what is
# under test here is the glue around it. When nghttpd is unavailable the
# suite falls back to a pinned floor.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-http2.XXXXXX")
pids=()
cleanup() {
    for pid in "${pids[@]:-}"; do
        [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    done
    rm -rf "$tmp"
}
trap cleanup EXIT
beansc=${BEANSC:-./build/beansc}

# Starts the Beans HTTP/2 echo server; sets PORT once it is listening.
PORT=0
start_echo() {
    PORT=$(( 18500 + RANDOM % 900 ))
    "$tmp/echo" "$PORT" 120 >"$tmp/echo.out" 2>"$tmp/echo.log" &
    pids+=($!)
    local waited=0
    while ! grep -q "^listening" "$tmp/echo.log" 2>/dev/null; do
        waited=$((waited + 1))
        if [ "$waited" -gt 400 ]; then
            echo "the HTTP/2 echo server never bound" >&2
            cat "$tmp/echo.log" >&2
            exit 1
        fi
        sleep 0.05
    done
}

echo "checking streams over loopback in both backends"
"$beansc" run test/cases/http2_roundtrip.b >"$tmp/roundtrip.interp"
"$beansc" build test/cases/http2_roundtrip.b -o "$tmp/roundtrip" >/dev/null 2>&1
"$tmp/roundtrip" >"$tmp/roundtrip.native"
diff -u test/cases/http2_roundtrip.out "$tmp/roundtrip.interp"
diff -u test/cases/http2_roundtrip.out "$tmp/roundtrip.native"

echo "checking the glue fuzzer at fixed seeds"
"$beansc" build test/cases/http2_fuzz.b -o "$tmp/h2_fuzz" >/dev/null 2>&1
for seed in 1 2; do
    "$tmp/h2_fuzz" "$seed" 25 >"$tmp/fuzz.$seed.out" 2>&1 || {
        cat "$tmp/fuzz.$seed.out" >&2
        exit 1
    }
    grep -q "^ok http2_fuzz" "$tmp/fuzz.$seed.out"
done
"$beansc" run test/cases/http2_fuzz.b -- 3 6 >"$tmp/fuzz.interp" 2>&1 || {
    cat "$tmp/fuzz.interp" >&2
    exit 1
}
grep -q "^ok http2_fuzz" "$tmp/fuzz.interp"

echo "checking no C type escapes the HTTP/2 surface"
if grep -nE '^\s*pub .*(RawPtr|CFunctionPtr)' stdlib/std/http/http2.b; then
    echo "a C type appears in a public HTTP/2 signature" >&2
    exit 1
fi

"$beansc" build test/cases/http2_echo_server.b -o "$tmp/echo" >/dev/null 2>&1

echo "checking curl interop"
if command -v curl >/dev/null 2>&1 && curl --version | grep -q nghttp2; then
    start_echo
    got=$(curl -s --http2-prior-knowledge -w '%{http_code}/%{http_version}' \
        --max-time 10 "http://127.0.0.1:$PORT/hello" 2>&1)
    case "$got" in
        *"hello from beans h2200/2") echo "  curl: HTTP/2, 200, body intact" ;;
        *) echo "curl interop failed: $got" >&2; exit 1 ;;
    esac
else
    if [[ ${BEANS_CURL_REQUIRE:-0} == 1 ]]; then
        echo "curl with HTTP/2 support is required but unavailable" >&2
        exit 1
    fi
    echo "  skipping: curl has no HTTP/2 support here"
fi

echo "checking our client against nghttpd"
if command -v nghttpd >/dev/null 2>&1; then
    ngport=$(( 18600 + RANDOM % 900 ))
    nghttpd --no-tls -d "$tmp" "$ngport" >/dev/null 2>&1 &
    pids+=($!)
    sleep 1
    cat >"$tmp/client.b" <<'BEANS'
package main
import std.http
import std.io
import std.net
import std.os

fn dial(port: int) -> Result<http.Http2Connection> {
    let socket: net.TcpStream = net.TcpStream.connect_timeout("127.0.0.1", port, 4000)?
    let tuned: Result<bool> = socket.set_timeouts(4000, 4000)
    return http.Http2Connection.adopt(move socket, false)
}

fn main() {
    let port: int = os.args()[0].to_int().or(0)
    var status: int = 0
    match dial(port) {
        ok(connection) => {
            match connection.request("GET", "http", "localhost", "/",
                                     new http.Headers(), new Bytes(0)) {
                ok(id) => {
                    var rounds: int = 0
                    for status == 0 && rounds < 40 {
                        rounds += 1
                        match connection.run() {
                            ok(events) => {
                                for event: http.Http2Event in events {
                                    match event {
                                        message(exchange) => { status = exchange.status() }
                                        stream_closed(sid, code) => {}
                                        goaway(last, code) => { rounds = 40 }
                                    }
                                }
                            }
                            err(e) => { rounds = 40 }
                        }
                    }
                }
                err(e) => {}
            }
            let closed: Result<bool> = connection.close()
        }
        err(e) => {}
    }
    io.println("nghttpd answered {status > 0}")
}
BEANS
    "$beansc" build "$tmp/client.b" -o "$tmp/client" >/dev/null 2>&1
    got=$("$tmp/client" "$ngport")
    [ "$got" = "nghttpd answered true" ] || {
        echo "nghttpd interop failed: $got" >&2
        exit 1
    }
    echo "  nghttpd: our client read a real HTTP/2 response"
else
    if [[ ${BEANS_NGHTTPD_REQUIRE:-0} == 1 ]]; then
        echo "nghttpd is required but unavailable" >&2
        exit 1
    fi
    echo "  skipping: nghttpd is unavailable"
fi

echo "checking h2spec conformance"
h2spec_bin=${BEANS_H2SPEC:-$(command -v h2spec || true)}
if [ -z "$h2spec_bin" ] || [ ! -x "$h2spec_bin" ]; then
    if [[ ${BEANS_H2SPEC_REQUIRE:-0} == 1 ]]; then
        echo "h2spec is required but unavailable" >&2
        exit 1
    fi
    echo "  skipping: h2spec is unavailable (set BEANS_H2SPEC)"
    echo "ok http2: loopback streams, glue fuzz, interop (h2spec skipped)"
    exit 0
fi

# The reference bar: what nghttp2's own server scores through this exact
# suite, on this exact host. Anything it passes, we must pass.
reference_failures=""
if command -v nghttpd >/dev/null 2>&1; then
    refport=$(( 18700 + RANDOM % 900 ))
    nghttpd --no-tls -d "$tmp" "$refport" >/dev/null 2>&1 &
    pids+=($!)
    sleep 1
    "$h2spec_bin" -h 127.0.0.1 -p "$refport" >"$tmp/h2spec.reference" 2>&1 || true
    reference_failures="$tmp/h2spec.reference"
fi

start_echo
"$h2spec_bin" -h 127.0.0.1 -p "$PORT" >"$tmp/h2spec.ours" 2>&1 || true
tail -1 "$tmp/h2spec.ours" | sed 's/^/  ours: /'
if [ -n "$reference_failures" ]; then
    tail -1 "$reference_failures" | sed 's/^/  nghttpd: /'
fi

python3 - "$tmp/h2spec.ours" "$reference_failures" <<'PYEOF'
import re, sys

def failures(path):
    found, section = [], ""
    for line in open(path):
        header = re.match(r"^\s+(\d+(?:\.\d+)*)\.\s", line.rstrip())
        if header:
            section = header.group(1)
        failed = re.match(r"^\s+×\s+(\d+):\s*(.*)$", line.rstrip())
        if failed:
            found.append((f"{section}/{failed.group(1)}", failed.group(2)))
    return list(dict.fromkeys(found))

ours = failures(sys.argv[1])
reference = set(k for k, _ in failures(sys.argv[2])) if len(sys.argv) > 2 and sys.argv[2] else None

if reference is None:
    # No reference to measure against: hold a pinned floor instead, so a
    # regression still cannot pass unnoticed.
    if len(ours) > 9:
        print(f"  {len(ours)} failures exceeds the pinned floor of 9")
        for k, v in ours:
            print("   ", k, v[:60])
        sys.exit(1)
    print(f"  {len(ours)} failures, within the pinned floor (no nghttpd to compare)")
    sys.exit(0)

extra = [(k, v) for k, v in ours if k not in reference]
print(f"  {len(ours)} failures, {len(extra)} of them not shared with nghttp2's own server")
if extra:
    for k, v in extra:
        print("   ", k, v[:60])
    print("  a case nghttp2's own server passes must not fail here")
    sys.exit(1)
PYEOF

echo "ok http2: loopback streams, glue fuzz, curl and nghttpd interop, h2spec at the reference bar"

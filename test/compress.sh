#!/usr/bin/env bash
# std.compress: round-trip properties across formats, levels, flush points
# and buffer shapes; the limit boundary exact to the byte; streaming equal
# to one-shot; bomb refusal; mutation/truncation fuzz at fixed seeds; and
# system-gzip interop in both directions, multi-member included. The
# Content-Encoding lane proves an HTTP client decompresses a gzip response
# under the same limits.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-compress.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
beansc=${BEANSC:-./build/beansc}

run_both() {
    local name=$1
    "$beansc" run "test/cases/$name.b" >"$tmp/$name.interp"
    "$beansc" build "test/cases/$name.b" -o "$tmp/$name.native" \
        >"$tmp/$name.build" 2>&1
    "$tmp/$name.native" >"$tmp/$name.native.out"
    diff -u "test/cases/$name.out" "$tmp/$name.interp"
    diff -u "test/cases/$name.out" "$tmp/$name.native.out"
}

echo "checking round-trip properties, limits, streaming, bombs"
run_both compress_roundtrip

echo "checking mutation fuzz at fixed seeds"
"$beansc" build test/cases/compress_fuzz.b -o "$tmp/compress_fuzz" >/dev/null 2>&1
"$tmp/compress_fuzz" 1 400 >"$tmp/fuzz1.out" || { cat "$tmp/fuzz1.out" >&2; exit 1; }
grep -q "^ok compress_fuzz" "$tmp/fuzz1.out"
"$tmp/compress_fuzz" 2 400 >"$tmp/fuzz2.out" || { cat "$tmp/fuzz2.out" >&2; exit 1; }
grep -q "^ok compress_fuzz" "$tmp/fuzz2.out"
"$beansc" run test/cases/compress_fuzz.b -- 3 60 >"$tmp/fuzz3.out" || { cat "$tmp/fuzz3.out" >&2; exit 1; }
grep -q "^ok compress_fuzz" "$tmp/fuzz3.out"

echo "checking system gzip interop"
if command -v gzip >/dev/null 2>&1; then
    "$beansc" build test/cases/compress_cli.b -o "$tmp/compress_cli" >/dev/null 2>&1
    # A payload with both compressible and awkward regions.
    head -c 200000 /dev/urandom >"$tmp/sample" 2>/dev/null || {
        for i in $(seq 1 4000); do echo "line $i of the interop sample"; done >"$tmp/sample"
    }
    for i in $(seq 1 200); do echo "compressible line $i" >>"$tmp/sample"; done
    # ours -> system gzip
    "$tmp/compress_cli" pack "$tmp/sample" "$tmp/ours.gz" >/dev/null
    gzip -dc <"$tmp/ours.gz" >"$tmp/ours.out"
    cmp "$tmp/sample" "$tmp/ours.out"
    # system gzip -> ours
    gzip -c9 <"$tmp/sample" >"$tmp/system.gz"
    "$tmp/compress_cli" unpack "$tmp/system.gz" "$tmp/system.out" >/dev/null
    cmp "$tmp/sample" "$tmp/system.out"
    # multi-member: two system members read as one stream by ours
    cat "$tmp/system.gz" "$tmp/system.gz" >"$tmp/double.gz"
    "$tmp/compress_cli" unpack "$tmp/double.gz" "$tmp/double.out" >/dev/null
    cat "$tmp/sample" "$tmp/sample" >"$tmp/double.expect"
    cmp "$tmp/double.expect" "$tmp/double.out"
    echo "gzip interop: both directions and multi-member agree"
else
    if [[ ${BEANS_GZIP_REQUIRE:-0} == 1 ]]; then
        echo "system gzip is required but unavailable" >&2
        exit 1
    fi
    echo "skipping system gzip interop: gzip is unavailable"
fi

echo "checking Content-Encoding rides the client with the same limits"
cat >"$tmp/encoded.b" <<'BEANS'
package main

import std.compress
import std.http
import std.io
import std.net
import std.thread

fn main() {
    match net.TcpListener.bind("127.0.0.1", 0) {
        ok(listener) => {
            let port: int = listener.port().expect("port")
            let visitor: Thread<int> = thread.spawn(fn() -> int {
                var failures: int = 0
                match http.Client.connect("127.0.0.1", port) {
                    ok(client) => {
                        match client.get("/packed") {
                            ok(answer) => {
                                if answer.body.to_string() != "decompressed just fine, twelve words of payload to make it worth compressing" { failures += 1 }
                            }
                            err(_) => { failures += 10 }
                        }
                        client.set_max_body(16)
                        match client.get("/packed") {
                            ok(_) => { failures += 1 }
                            err(e) => {
                                if e.kind != "limit" && e.kind != "too_large" { failures += 1 }
                            }
                        }
                    }
                    err(_) => { failures += 100 }
                }
                return failures
            })
            var served: int = 0
            match listener.accept() {
                ok(conn) => {
                    let tuned: Result<bool> = conn.set_timeouts(8000, 8000)
                    let body: string = "decompressed just fine, twelve words of payload to make it worth compressing"
                    match compress.gzip_compress(Bytes.from(body)) {
                        ok(packed) => {
                            for round: int in 0..2 {
                                match conn.read(65536) {
                                    ok(request) => {
                                        if request.len() > 0 {
                                            var reply: Bytes = new Bytes(0)
                                            reply.append_string("HTTP/1.1 200 OK\r\n")
                                            reply.append_string("Content-Encoding: gzip\r\n")
                                            reply.append_string("Content-Length: {packed.len()}\r\n")
                                            reply.append_string("\r\n")
                                            reply.append(packed)
                                            match conn.write_all(reply) {
                                                ok(_) => { served += 1 }
                                                err(_) => {}
                                            }
                                        }
                                    }
                                    err(_) => {}
                                }
                            }
                        }
                        err(_) => {}
                    }
                }
                err(_) => {}
            }
            io.println("gzip responses served {served == 2}")
            io.println("client decoded and limited {visitor.join() == 0}")
        }
        err(e) => { io.println("bind failed: {e.kind}") }
    }
}
BEANS
"$beansc" run "$tmp/encoded.b" >"$tmp/encoded.interp"
"$beansc" build "$tmp/encoded.b" -o "$tmp/encoded" >/dev/null 2>&1
"$tmp/encoded" >"$tmp/encoded.native"
diff -u - "$tmp/encoded.interp" <<'EXPECTED'
gzip responses served true
client decoded and limited true
EXPECTED
diff -u "$tmp/encoded.interp" "$tmp/encoded.native"

echo "ok compress: properties, limits, streaming, fuzz, gzip interop, content-encoding"

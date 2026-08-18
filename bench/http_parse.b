// HTTP/1.1 parse throughput — the trampoline-budget gate.
//
// The same 465-byte request the raw-llhttp reference bench parses, pushed
// through the public std.http RequestParser with all events consumed. The
// done-gate from the net stack plan: parse-only throughput within 2x of
// raw llhttp (empty settings), which is the cost budget for the event
// buffer, the Beans-side decode, and the typed event objects.
//
// Prints MB/s; test/http.sh compares against the C reference built from
// the same vendored sources.
package main

import std.http
import std.io
import std.time

fn main() {
    var wire: Bytes = new Bytes(0)
    wire.append_string("POST /api/v1/items?limit=25&cursor=abc123 HTTP/1.1\r\n")
    wire.append_string("Host: bench.example.test:8080\r\n")
    wire.append_string("User-Agent: bench-client/1.0 (llhttp comparison)\r\n")
    wire.append_string("Accept: application/json, text/plain;q=0.9, */*;q=0.1\r\n")
    wire.append_string("Accept-Encoding: gzip, deflate\r\n")
    wire.append_string("Content-Type: application/json; charset=utf-8\r\n")
    wire.append_string("X-Request-Id: 4a1c9bd2-77e3-4b21-9d3a-52a7cf80e9b1\r\n")
    wire.append_string("Authorization: Bearer wSJd82jdiwjdksjw.kdjwidjw.dkjwidjqqp\r\n")
    wire.append_string("Content-Length: 64\r\n")
    wire.append_string("\r\n")
    wire.append_string("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")

    let parser: http.RequestParser = new http.RequestParser()
    let rounds: int = 200000
    var heads: int = 0
    var body_bytes: int = 0
    let started: int = time.monotonic_nanos()
    for round: int in 0..rounds {
        match parser.feed(wire) {
            ok(events) => {
                for event: http.RequestEvent in events {
                    match event {
                        head(request) => { heads += 1 }
                        body(data) => { body_bytes += data.len() }
                        trailers(fields) => {}
                        done(keep_alive) => {}
                        upgraded(request, remainder) => {}
                    }
                }
            }
            err(e) => {
                io.println("parse failed: {e.msg}")
                return
            }
        }
    }
    let elapsed: int = time.monotonic_nanos() - started
    let total: int = wire.len() * rounds
    // MB/s with two decimals, in integer math.
    let mb_hundredths: int = total * 100000 * 1000 / 1048576 / elapsed * 1000
    let whole: int = mb_hundredths / 100
    let frac: int = mb_hundredths % 100
    io.println("std.http: {total / 1048576} MB, {heads} messages, {body_bytes / 1048576} MB body")
    io.println("std.http: {whole}.{frac} MB/s")
}

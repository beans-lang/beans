// Hashing from the platform, and the one place a WebSocket handshake needs
// it. Two things to notice:
//
//   The digests come from the OS crypto library — CommonCrypto, CNG, or
//   libcrypto — never from an implementation shipped here. A hash is
//   exactly the kind of thing you take rather than carry.
//
//   `Sec-WebSocket-Accept` is SHA-1 over the client key and one fixed UUID,
//   base64-encoded. Getting it wrong fails a real handshake, which is why
//   the published example value is worth checking against.
package main

import std.crypto
import std.encoding.base64
import std.io

fn hex(data: Bytes) -> string {
    var out: string = ""
    let digits: string = "0123456789abcdef"
    for index: int in 0..data.len() {
        let byte: int = data.get(index)
        out = "{out}{digits.slice(byte / 16, byte / 16 + 1)}{digits.slice(byte % 16, byte % 16 + 1)}"
    }
    return out
}

fn main() {
    io.println("a hash provider is available {crypto.available()}")

    // FIPS 180's own vector, so a wrong platform binding is obvious.
    match crypto.sha256(Bytes.from("abc")) {
        ok(digest) => {
            let want: string =
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
            io.println("sha256(\"abc\") matches FIPS 180 {hex(digest) == want}")
        }
        err(e) => { io.println("sha256 failed: {e.kind}") }
    }

    // Streaming: the digest does not care how the bytes arrived.
    match crypto.Hasher.open(crypto.Algorithm.sha256) {
        ok(hasher) => {
            let a: Result<bool> = hasher.update(Bytes.from("a"))
            let b: Result<bool> = hasher.update(Bytes.from("bc"))
            match hasher.finish() {
                ok(digest) => {
                    let want: string =
                        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
                    io.println("streamed in pieces, same digest {hex(digest) == want}")
                }
                err(e) => { io.println("finish failed: {e.kind}") }
            }
        }
        err(e) => { io.println("hasher failed: {e.kind}") }
    }

    // HMAC, RFC 4231's first case.
    var key: Bytes = new Bytes(20)
    key.fill(0x0b)
    match crypto.hmac(crypto.Algorithm.sha256, key, Bytes.from("Hi There")) {
        ok(mac) => {
            let want: string =
                "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
            io.println("hmac-sha256 matches RFC 4231 {hex(mac) == want}")
        }
        err(e) => { io.println("hmac failed: {e.kind}") }
    }

    // The WebSocket accept value from RFC 6455.
    let client_key: string = "dGhlIHNhbXBsZSBub25jZQ=="
    let websocket_uuid: string = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    match crypto.sha1(Bytes.from("{client_key}{websocket_uuid}")) {
        ok(digest) => {
            io.println("websocket accept matches RFC 6455 {base64.encode(digest) == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="}")
        }
        err(e) => { io.println("sha1 failed: {e.kind}") }
    }
}

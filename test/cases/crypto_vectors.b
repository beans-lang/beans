// std.crypto against published test vectors: SHA-1 and SHA-256 from FIPS
// 180, HMAC-SHA1/256 from RFC 2202 and RFC 4231, the streaming digest
// equal to the one-shot, and the WebSocket accept value from RFC 6455 — a
// wrong digest fails a real handshake, so this is the interop gate SHA-1
// exists to serve. Every hash comes from the platform provider; the vectors
// are what keep three OS backends honest against one contract.
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

fn repeat_byte(value: int, count: int) -> Bytes {
    var out: Bytes = new Bytes(count)
    out.fill(value)
    return out
}

fn check(name: string, got: string, want: string) {
    io.println("{name} {got == want}")
}

fn main() {
    io.println("provider available {crypto.available()}")

    // FIPS 180 digest vectors.
    match crypto.sha1(Bytes.from("abc")) {
        ok(d) => { check("sha1 abc", hex(d), "a9993e364706816aba3e25717850c26c9cd0d89d") }
        err(e) => { io.println("sha1 abc failed {e.kind}") }
    }
    match crypto.sha1(Bytes.from("")) {
        ok(d) => { check("sha1 empty", hex(d), "da39a3ee5e6b4b0d3255bfef95601890afd80709") }
        err(e) => { io.println("sha1 empty failed {e.kind}") }
    }
    match crypto.sha1(Bytes.from("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")) {
        ok(d) => { check("sha1 long", hex(d), "84983e441c3bd26ebaae4aa1f95129e5e54670f1") }
        err(e) => { io.println("sha1 long failed {e.kind}") }
    }
    match crypto.sha256(Bytes.from("abc")) {
        ok(d) => { check("sha256 abc", hex(d), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad") }
        err(e) => { io.println("sha256 abc failed {e.kind}") }
    }
    match crypto.sha256(Bytes.from("")) {
        ok(d) => { check("sha256 empty", hex(d), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855") }
        err(e) => { io.println("sha256 empty failed {e.kind}") }
    }

    // HMAC-SHA1, RFC 2202 test case 1.
    match crypto.hmac(crypto.Algorithm.sha1, repeat_byte(0x0b, 20), Bytes.from("Hi There")) {
        ok(d) => { check("hmac-sha1 rfc2202-1", hex(d), "b617318655057264e28bc0b6fb378c8ef146be00") }
        err(e) => { io.println("hmac-sha1 failed {e.kind}") }
    }
    // HMAC-SHA1, RFC 2202 test case 2: key="Jefe", data="what do ya want for nothing?"
    match crypto.hmac(crypto.Algorithm.sha1, Bytes.from("Jefe"), Bytes.from("what do ya want for nothing?")) {
        ok(d) => { check("hmac-sha1 rfc2202-2", hex(d), "effcdf6ae5eb2fa2d27416d5f184df9c259a7c79") }
        err(e) => { io.println("hmac-sha1-2 failed {e.kind}") }
    }
    // HMAC-SHA256, RFC 4231 test case 1.
    match crypto.hmac(crypto.Algorithm.sha256, repeat_byte(0x0b, 20), Bytes.from("Hi There")) {
        ok(d) => { check("hmac-sha256 rfc4231-1", hex(d), "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7") }
        err(e) => { io.println("hmac-sha256 failed {e.kind}") }
    }
    // HMAC-SHA256 with a key longer than the block, RFC 4231 test case 6.
    match crypto.hmac(crypto.Algorithm.sha256, repeat_byte(0xaa, 131), Bytes.from("Test Using Larger Than Block-Size Key - Hash Key First")) {
        ok(d) => { check("hmac-sha256 rfc4231-6", hex(d), "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54") }
        err(e) => { io.println("hmac-sha256-6 failed {e.kind}") }
    }

    // Streaming equals one-shot: three updates over "abc".
    match crypto.Hasher.open(crypto.Algorithm.sha256) {
        ok(hasher) => {
            let a: Result<bool> = hasher.update(Bytes.from("a"))
            let b: Result<bool> = hasher.update(Bytes.from("b"))
            let c: Result<bool> = hasher.update(Bytes.from("c"))
            match hasher.finish() {
                ok(d) => { check("streaming equals one-shot", hex(d), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad") }
                err(e) => { io.println("streaming failed {e.kind}") }
            }
        }
        err(e) => { io.println("hasher open failed {e.kind}") }
    }

    // A finished hasher refuses more work.
    match crypto.Hasher.open(crypto.Algorithm.sha1) {
        ok(hasher) => {
            let updated: Result<bool> = hasher.update(Bytes.from("x"))
            let first: Result<Bytes> = hasher.finish()
            match hasher.update(Bytes.from("y")) {
                ok(_) => { io.println("spent hasher accepted more work") }
                err(e) => { check("spent hasher refuses", e.kind, "closed") }
            }
        }
        err(e) => { io.println("hasher open failed {e.kind}") }
    }

    // The WebSocket Sec-WebSocket-Accept from RFC 6455 section 1.3.
    let ws_key: string = "dGhlIHNhbXBsZSBub25jZQ=="
    let magic: string = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    match crypto.sha1(Bytes.from("{ws_key}{magic}")) {
        ok(digest) => { check("rfc6455 accept", base64.encode(digest), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=") }
        err(e) => { io.println("ws accept failed {e.kind}") }
    }
}

// std.encoding.base64: the RFC 4648 test vectors, all four encodings,
// strict versus forgiving decoding, invalid characters with positions, bad
// lengths, non-zero padding bits, whitespace policy, empty input, and a
// multi-megabyte round trip. Interpreter and native output must be
// byte-identical.

import std.io
import std.encoding.base64

fn show_decode(label: string, outcome: Result<Bytes>) {
    match outcome {
        ok(data) => io.println("{label}: ok [{data.to_string()}]"),
        err(e) => io.println("{label}: {e.kind} - {e.msg}"),
    }
}

fn main() {
    // RFC 4648 section 10 vectors
    let vectors: List<string> = ["", "f", "fo", "foo", "foob", "fooba", "foobar"]
    for vector: string in vectors {
        let encoded: string = base64.encode(Bytes.from(vector))
        var back: string = ""
        match base64.decode(encoded) {
            ok(data) => { back = data.to_string() }
            err(e) => { back = "err {e.kind}" }
        }
        let verdict: string = if back == vector { "ok" } else { "MISMATCH" }
        io.println("vector [{vector}] -> [{encoded}] {verdict}")
    }

    // all four encodings over bytes that exercise both special characters
    var special: Bytes = new Bytes(0)
    special.push(251)
    special.push(239)
    special.push(190)
    io.println("std      {base64.Encoding.standard.encode(special)}")
    io.println("std_raw  {base64.Encoding.standard_no_pad.encode(special)}")
    io.println("url      {base64.Encoding.url_safe.encode(special)}")
    io.println("url_raw  {base64.Encoding.url_safe_no_pad.encode(special)}")
    let padded: Bytes = Bytes.from("f")
    io.println("pad std  {base64.Encoding.standard.encode(padded)}")
    io.println("pad none {base64.Encoding.standard_no_pad.encode(padded)}")
    io.println("pad url  {base64.Encoding.url_safe.encode(padded)}")
    io.println("pad urlN {base64.Encoding.url_safe_no_pad.encode(padded)}")

    // each encoding decodes its own output
    match base64.Encoding.url_safe_no_pad.decode("-_8") {
        ok(data) => io.println("url decode {data.get(0)} {data.get(1)}"),
        err(e) => io.println("url decode err {e.msg}"),
    }

    // wrong alphabet for the encoding is an invalid character with position
    show_decode("plus in url", base64.Encoding.url_safe.decode("Zm+v"))
    show_decode("dash in std", base64.decode("Zm-v"))

    // strict rejections: whitespace, missing padding, stray padding,
    // non-zero trailing bits, lone character
    show_decode("strict ws", base64.decode("Zm9v\nYg=="))
    show_decode("strict tab", base64.decode("\tZm9v"))
    show_decode("missing pad", base64.decode("Zm9vYg"))
    show_decode("pad on raw", base64.Encoding.standard_no_pad.decode("Zm9vYg=="))
    show_decode("extra bits", base64.decode("QR=="))
    show_decode("lone char", base64.decode("Zm9vY"))
    show_decode("inner pad", base64.decode("Zm=vYg=="))
    show_decode("bang", base64.decode("Zm9!Yg=="))

    // forgiving mode: whitespace and partial groups pass, garbage still fails
    show_decode("forgiving ws", base64.decode_forgiving("Zm9v\n  Yg=="))
    show_decode("forgiving raw", base64.decode_forgiving("Zm9vYg"))
    show_decode("forgiving bits", base64.decode_forgiving("QR=="))
    show_decode("forgiving bang", base64.decode_forgiving("Zm9!Yg=="))

    // empty input in both directions
    io.println("empty encode [{base64.encode(new Bytes(0))}]")
    show_decode("empty decode", base64.decode(""))

    // multi-megabyte round trip with a rolling checksum
    var big: Bytes = new Bytes(3000000)
    var seed: int = 41
    for index: int in 0..big.len() {
        seed = (seed * 1103515245 + 12345) % 2147483647
        big.set(index, seed % 256)
    }
    let big_encoded: string = base64.encode(big)
    io.println("big encoded len {big_encoded.len()}")
    match base64.decode(big_encoded) {
        ok(back) => {
            let same: bool = back == big
            io.println("big round trip {same} crc {back.crc32(0, back.len())}")
        }
        err(e) => io.println("big err {e.msg}"),
    }
}

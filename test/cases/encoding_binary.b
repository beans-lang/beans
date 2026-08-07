// std.encoding.binary: both byte orders, every width and sign, float bit
// patterns including infinities, NaN and negative zero, varint boundaries
// matching Go, truncated and overflowing input, and the cursor types.
// Interpreter and native output must be byte-identical, and the pure-Beans
// implementation behaves the same on little- and big-endian targets — the
// big-endian proof rides the hosted CI gates that execute the whole test
// suite under qemu on s390x and ppc64.

import std.io
import std.encoding.binary

fn dump(label: string, data: Bytes) {
    var pieces: List<string> = []
    for index: int in 0..data.len() {
        pieces.push("{data.get(index)}")
    }
    io.println("{label} [{pieces.join(",")}]")
}

fn main() {
    let little: binary.ByteOrder = binary.ByteOrder.little
    let big: binary.ByteOrder = binary.ByteOrder.big

    // every width and sign, boundary values, both orders
    var wire: Bytes = new Bytes(0)
    binary.append_u8(wire, 255)
    binary.append_i8(wire, -128)
    binary.append_u16(wire, 65535, big)
    binary.append_i16(wire, -32768, little)
    binary.append_u32(wire, 4294967295, big)
    binary.append_i32(wire, -2147483648, little)
    binary.append_u64(wire, 18446744073709551615, big)
    binary.append_i64(wire, -9223372036854775808, little)
    dump("wire", wire)
    io.println("u8  {binary.read_u8(wire, 0).or(0)}")
    io.println("i8  {binary.read_i8(wire, 1).or(0)}")
    io.println("u16 {binary.read_u16(wire, 2, big).or(0)}")
    io.println("i16 {binary.read_i16(wire, 4, little).or(0)}")
    io.println("u32 {binary.read_u32(wire, 6, big).or(0)}")
    io.println("i32 {binary.read_i32(wire, 10, little).or(0)}")
    io.println("u64 {binary.read_u64(wire, 14, big).or(0)}")
    io.println("i64 {binary.read_i64(wire, 22, little).or(0)}")

    // order asymmetry is visible in the raw bytes
    var pair: Bytes = new Bytes(0)
    binary.append_u16(pair, 0x1234, little)
    binary.append_u16(pair, 0x1234, big)
    dump("order", pair)
    io.println("cross read {binary.read_u16(pair, 0, big).or(0)}")

    // in-place writes at positions, and their range errors
    var slab: Bytes = new Bytes(8)
    binary.write_u32(slab, 0, 0xdeadbeef, big).expect("write")
    binary.write_u32(slab, 4, 0xdeadbeef, little).expect("write")
    dump("slab", slab)
    match binary.write_u32(slab, 6, 1, big) {
        ok(_) => io.println("bad write accepted"),
        err(e) => io.println("write oob {e.kind}"),
    }
    match binary.write_u8(slab, -1, 1) {
        ok(_) => io.println("bad write accepted"),
        err(e) => io.println("write neg {e.kind}"),
    }

    // float bit patterns: infinities, quiet NaN, negative zero, both orders
    let zero: float = 0.0
    let one: float = 1.0
    var floats: Bytes = new Bytes(0)
    binary.append_f64(floats, one / zero, big)
    binary.append_f64(floats, (0.0 - 1.0) / zero, little)
    binary.append_f64(floats, zero / zero, big)
    binary.append_f64(floats, -0.0, big)
    binary.append_f32(floats, 1.5, little)
    dump("float head", floats.slice(0, 8))
    match binary.read_f64(floats, 0, big) {
        ok(v) => io.println("inf {v} again {v == one / zero}"),
        err(e) => io.println("err {e.msg}"),
    }
    match binary.read_f64(floats, 8, little) {
        ok(v) => io.println("-inf {v}"),
        err(e) => io.println("err {e.msg}"),
    }
    match binary.read_f64(floats, 16, big) {
        ok(v) => io.println("nan self-equal {v == v}"),
        err(e) => io.println("err {e.msg}"),
    }
    match binary.read_f64(floats, 24, big) {
        ok(v) => io.println("negzero {v} sign-preserved {one / v == (0.0 - 1.0) / zero}"),
        err(e) => io.println("err {e.msg}"),
    }
    match binary.read_f32(floats, 32, little) {
        ok(v) => io.println("f32 {v}"),
        err(e) => io.println("err {e.msg}"),
    }
    // NaN payload bits survive the byte round trip exactly
    var nan_copy: Bytes = new Bytes(0)
    match binary.read_f64(floats, 16, big) {
        ok(v) => { binary.append_f64(nan_copy, v, big) }
        err(_) => {}
    }
    io.println("nan bits stable {nan_copy == floats.slice(16, 24)}")

    // truncated reads are eof errors, never panics
    let short: Bytes = Bytes.from("ab")
    match binary.read_u32(short, 0, little) {
        ok(_) => io.println("bad read accepted"),
        err(e) => io.println("truncated {e.kind} - {e.msg}"),
    }
    match binary.read_u8(short, 2) {
        ok(_) => io.println("bad read accepted"),
        err(e) => io.println("past end {e.kind}"),
    }

    // unsigned varints: Go's Uvarint boundaries
    var uv: Bytes = new Bytes(0)
    binary.append_uvarint(uv, 0)
    binary.append_uvarint(uv, 127)
    binary.append_uvarint(uv, 128)
    binary.append_uvarint(uv, 300)
    binary.append_uvarint(uv, 18446744073709551615)
    dump("uvarint", uv)
    var cursor: int = 0
    for cursor < uv.len() {
        match binary.read_uvarint(uv, cursor) {
            ok(read) => {
                io.println("uvarint {read.value} size {read.size}")
                cursor += read.size
            }
            err(e) => {
                io.println("err {e.msg}")
                cursor = uv.len()
            }
        }
    }
    io.println("uvarint_size 127 {binary.uvarint_size(127)} 128 {binary.uvarint_size(128)} max {binary.uvarint_size(18446744073709551615)}")

    // signed zigzag varints: Go's Varint byte patterns
    var sv: Bytes = new Bytes(0)
    binary.append_varint(sv, 0)
    binary.append_varint(sv, -1)
    binary.append_varint(sv, 1)
    binary.append_varint(sv, -2)
    binary.append_varint(sv, 2)
    binary.append_varint(sv, 9223372036854775807)
    binary.append_varint(sv, -9223372036854775808)
    dump("varint", sv)
    var sv_cursor: int = 0
    for sv_cursor < sv.len() {
        match binary.read_varint(sv, sv_cursor) {
            ok(read) => {
                io.println("varint {read.value} size {read.size}")
                sv_cursor += read.size
            }
            err(e) => {
                io.println("err {e.msg}")
                sv_cursor = sv.len()
            }
        }
    }

    // truncated and overflowing varints
    var cut: Bytes = new Bytes(0)
    cut.push(0x80)
    cut.push(0x80)
    match binary.read_uvarint(cut, 0) {
        ok(_) => io.println("bad varint accepted"),
        err(e) => io.println("varint cut {e.kind}"),
    }
    var wide: Bytes = new Bytes(0)
    for index: int in 0..9 { wide.push(0x80) }
    wide.push(0x02)
    match binary.read_uvarint(wide, 0) {
        ok(_) => io.println("bad varint accepted"),
        err(e) => io.println("varint overflow {e.kind}"),
    }
    var long: Bytes = new Bytes(0)
    for index: int in 0..10 { long.push(0x80) }
    long.push(0x01)
    match binary.read_uvarint(long, 0) {
        ok(_) => io.println("bad varint accepted"),
        err(e) => io.println("varint long {e.kind}"),
    }

    // the ten-byte pattern Bytes.append_uvarint uses for -1 stays readable
    var compat: Bytes = new Bytes(0)
    compat.append_uvarint(-1)
    io.println("legacy len {compat.len()} value {compat.get_uvarint(0)}")
    match binary.read_uvarint(compat, 0) {
        ok(read) => io.println("legacy as uvarint {read.value} size {read.size}"),
        err(e) => io.println("err {e.msg}"),
    }

    // cursors: sequential reads, remaining, skip, and a writer
    var frame: Bytes = new Bytes(0)
    binary.append_u16(frame, 2026, big)
    binary.append_uvarint(frame, 300)
    binary.append_f32(frame, 0.25, big)
    binary.append_varint(frame, -40)
    let reader: binary.Reader = new binary.Reader(big)
    io.println("r u16 {reader.read_u16(frame).or(0)} at {reader.position}")
    io.println("r uvarint {reader.read_uvarint(frame).or(0)} at {reader.position}")
    io.println("r f32 {reader.read_f32(frame).or(0.0)} at {reader.position}")
    io.println("r varint {reader.read_varint(frame).or(0)} left {reader.remaining(frame)}")
    match reader.read_u8(frame) {
        ok(_) => io.println("bad cursor read accepted"),
        err(e) => io.println("cursor end {e.kind}"),
    }

    var out: Bytes = new Bytes(6)
    let writer: binary.Writer = new binary.Writer(little)
    writer.write_u16(out, 0x0102).expect("write")
    writer.write_u32(out, 0x03040506).expect("write")
    dump("writer", out)
    match writer.write_u8(out, 1) {
        ok(_) => io.println("bad cursor write accepted"),
        err(e) => io.println("writer full {e.kind}"),
    }

    // native order matches exactly one of the fixed orders
    var native_probe: Bytes = new Bytes(0)
    binary.append_u16(native_probe, 0x0102, binary.ByteOrder.native)
    let first: int = native_probe.get(0)
    io.println("native matches little {first == 2} big {first == 1}")
}

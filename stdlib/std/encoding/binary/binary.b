// Fixed-width and varint binary encoding over Bytes, written in Beans.
//
// The native Bytes word accessors stay the storage primitives: they are
// little-endian and panic when out of range. This package adds the checked
// layer — explicit byte order, Result errors instead of panics, bit-preserving
// float conversion, cursors, and Go-compatible varints.
//
// Byte-order model: `ByteOrder.little`, `ByteOrder.big`, or
// `ByteOrder.native`, which resolves to the selected target's order at
// compile time through std.target. Reads and writes never touch memory
// outside the checked range, and a truncated input is an error with kind
// "eof", never a panic.
//
// Varints: `append_uvarint`/`read_uvarint` are unsigned LEB128 over the
// 64-bit pattern — the same wire format as `Bytes.append_varint` and Go's
// `PutUvarint`. `append_varint`/`read_varint` are the signed zigzag form
// matching Go's `PutVarint`: -1 encodes as 1, 1 as 2, and every value takes
// its zigzag width rather than ten bytes for all negatives. `Bytes.
// append_varint` keeps its existing behaviour (the raw two's-complement
// pattern, ten bytes for negatives); the two signed conventions are
// different formats, named differently on purpose.

import std.target

pub enum ByteOrder {
    little
    big
    native

    fn is_little() -> bool {
        return match self {
            little => true,
            big => false,
            native => target.endian() == "little",
        }
    }
}

// ---- byte-pattern helpers (u64 domain: logical shifts) ----

fn swap16(value: u64) -> u64 {
    return ((value & 0xff) << 8) | ((value >> 8) & 0xff)
}

fn swap32(value: u64) -> u64 {
    return ((value & 0xff) << 24) |
           ((value & 0xff00) << 8) |
           ((value >> 8) & 0xff00) |
           ((value >> 24) & 0xff)
}

fn swap64(value: u64) -> u64 {
    return (swap32(value & 0xffffffff) << 32) | swap32(value >> 32)
}

fn check_range(data: Bytes, pos: int, width: int, op: string) -> Result<bool> {
    if pos < 0 || width > data.len() || pos > data.len() - width {
        return err("{op} of {width} bytes at {pos} is outside length {data.len()}", "eof")
    }
    return ok(true)
}

fn check_write_range(data: Bytes, pos: int, width: int, op: string) -> Result<bool> {
    if pos < 0 || width > data.len() || pos > data.len() - width {
        return err("{op} of {width} bytes at {pos} is outside length {data.len()}", "range")
    }
    return ok(true)
}

// Reads the little-endian pattern of `width` bytes, then corrects for order.
fn read_pattern(data: Bytes, pos: int, width: int, order: ByteOrder) -> u64 {
    var raw: u64 = 0
    if width == 1 {
        raw = data.get_u8(pos) as u64
    } else if width == 2 {
        raw = data.get_u16(pos) as u64
        if !order.is_little() { raw = swap16(raw) }
    } else if width == 4 {
        raw = data.get_u32(pos) as u64
        if !order.is_little() { raw = swap32(raw) }
    } else {
        raw = data.get_u64(pos) as u64
        if !order.is_little() { raw = swap64(raw) }
    }
    return raw
}

// Writes the low `width` bytes of `pattern` at `pos` in the given order.
fn write_pattern(data: Bytes, pos: int, width: int, pattern: u64, order: ByteOrder) {
    var wire: u64 = pattern
    if width == 1 {
        data.put_u8(pos, (wire & 0xff) as int)
        return
    }
    if width == 2 {
        if !order.is_little() { wire = swap16(wire & 0xffff) }
        data.put_u16(pos, (wire & 0xffff) as int)
        return
    }
    if width == 4 {
        if !order.is_little() { wire = swap32(wire & 0xffffffff) }
        data.put_u32(pos, (wire & 0xffffffff) as int)
        return
    }
    if !order.is_little() { wire = swap64(wire) }
    data.put_u64(pos, wire as int)
}

// Appends the low `width` bytes of `pattern` in wire order.
fn append_pattern(data: Bytes, width: int, pattern: u64, order: ByteOrder) {
    if order.is_little() {
        for index: int in 0..width {
            data.push(((pattern >> ((index * 8) as u64)) & 0xff) as int)
        }
        return
    }
    for index: int in 0..width {
        data.push(((pattern >> (((width - 1 - index) * 8) as u64)) & 0xff) as int)
    }
}

// ---- bit-preserving float conversion ----

fn f64_bits(value: float) -> u64 {
    var bits: u64 = 0
    unsafe {
        let slot: RawPtr<f64> = RawPtr.alloc(1)
        slot.write(value)
        let view: RawPtr<u64> = RawPtr.from_address(slot.address())
        bits = view.read()
        slot.free()
    }
    return bits
}

fn f64_from_bits(bits: u64) -> float {
    var value: float = 0.0
    unsafe {
        let slot: RawPtr<u64> = RawPtr.alloc(1)
        slot.write(bits)
        let view: RawPtr<f64> = RawPtr.from_address(slot.address())
        value = view.read()
        slot.free()
    }
    return value
}

fn f32_bits(value: f32) -> u64 {
    var bits: u64 = 0
    unsafe {
        let slot: RawPtr<f32> = RawPtr.alloc(1)
        slot.write(value)
        let view: RawPtr<u32> = RawPtr.from_address(slot.address())
        bits = view.read() as u64
        slot.free()
    }
    return bits
}

fn f32_from_bits(bits: u64) -> f32 {
    var value: f32 = 0.0
    unsafe {
        let slot: RawPtr<u32> = RawPtr.alloc(1)
        slot.write((bits & 0xffffffff) as u32)
        let view: RawPtr<f32> = RawPtr.from_address(slot.address())
        value = view.read()
        slot.free()
    }
    return value
}

// ---- positional reads ----

pub fn read_u8(data: Bytes, pos: int) -> Result<u8> {
    check_range(data, pos, 1, "read_u8")?
    return ok(data.get_u8(pos) as u8)
}

pub fn read_i8(data: Bytes, pos: int) -> Result<i8> {
    check_range(data, pos, 1, "read_i8")?
    return ok(data.get_u8(pos) as i8)
}

pub fn read_u16(data: Bytes, pos: int, order: ByteOrder) -> Result<u16> {
    check_range(data, pos, 2, "read_u16")?
    return ok(read_pattern(data, pos, 2, order) as u16)
}

pub fn read_i16(data: Bytes, pos: int, order: ByteOrder) -> Result<i16> {
    check_range(data, pos, 2, "read_i16")?
    return ok(read_pattern(data, pos, 2, order) as i16)
}

pub fn read_u32(data: Bytes, pos: int, order: ByteOrder) -> Result<u32> {
    check_range(data, pos, 4, "read_u32")?
    return ok(read_pattern(data, pos, 4, order) as u32)
}

pub fn read_i32(data: Bytes, pos: int, order: ByteOrder) -> Result<i32> {
    check_range(data, pos, 4, "read_i32")?
    return ok(read_pattern(data, pos, 4, order) as i32)
}

pub fn read_u64(data: Bytes, pos: int, order: ByteOrder) -> Result<u64> {
    check_range(data, pos, 8, "read_u64")?
    return ok(read_pattern(data, pos, 8, order))
}

pub fn read_i64(data: Bytes, pos: int, order: ByteOrder) -> Result<i64> {
    check_range(data, pos, 8, "read_i64")?
    return ok(read_pattern(data, pos, 8, order) as i64)
}

/// The stored 32-bit pattern, reproduced bit-for-bit: infinities, quiet NaN
/// payloads, and negative zero survive the round trip.
pub fn read_f32(data: Bytes, pos: int, order: ByteOrder) -> Result<f32> {
    check_range(data, pos, 4, "read_f32")?
    return ok(f32_from_bits(read_pattern(data, pos, 4, order)))
}

pub fn read_f64(data: Bytes, pos: int, order: ByteOrder) -> Result<float> {
    check_range(data, pos, 8, "read_f64")?
    return ok(f64_from_bits(read_pattern(data, pos, 8, order)))
}

// ---- positional writes ----

pub fn write_u8(data: Bytes, pos: int, value: u8) -> Result<bool> {
    check_write_range(data, pos, 1, "write_u8")?
    write_pattern(data, pos, 1, value as u64, ByteOrder.little)
    return ok(true)
}

pub fn write_i8(data: Bytes, pos: int, value: i8) -> Result<bool> {
    check_write_range(data, pos, 1, "write_i8")?
    write_pattern(data, pos, 1, (value as u8) as u64, ByteOrder.little)
    return ok(true)
}

pub fn write_u16(data: Bytes, pos: int, value: u16, order: ByteOrder) -> Result<bool> {
    check_write_range(data, pos, 2, "write_u16")?
    write_pattern(data, pos, 2, value as u64, order)
    return ok(true)
}

pub fn write_i16(data: Bytes, pos: int, value: i16, order: ByteOrder) -> Result<bool> {
    check_write_range(data, pos, 2, "write_i16")?
    write_pattern(data, pos, 2, (value as u16) as u64, order)
    return ok(true)
}

pub fn write_u32(data: Bytes, pos: int, value: u32, order: ByteOrder) -> Result<bool> {
    check_write_range(data, pos, 4, "write_u32")?
    write_pattern(data, pos, 4, value as u64, order)
    return ok(true)
}

pub fn write_i32(data: Bytes, pos: int, value: i32, order: ByteOrder) -> Result<bool> {
    check_write_range(data, pos, 4, "write_i32")?
    write_pattern(data, pos, 4, (value as u32) as u64, order)
    return ok(true)
}

pub fn write_u64(data: Bytes, pos: int, value: u64, order: ByteOrder) -> Result<bool> {
    check_write_range(data, pos, 8, "write_u64")?
    write_pattern(data, pos, 8, value, order)
    return ok(true)
}

pub fn write_i64(data: Bytes, pos: int, value: i64, order: ByteOrder) -> Result<bool> {
    check_write_range(data, pos, 8, "write_i64")?
    write_pattern(data, pos, 8, value as u64, order)
    return ok(true)
}

pub fn write_f32(data: Bytes, pos: int, value: f32, order: ByteOrder) -> Result<bool> {
    check_write_range(data, pos, 4, "write_f32")?
    write_pattern(data, pos, 4, f32_bits(value), order)
    return ok(true)
}

pub fn write_f64(data: Bytes, pos: int, value: float, order: ByteOrder) -> Result<bool> {
    check_write_range(data, pos, 8, "write_f64")?
    write_pattern(data, pos, 8, f64_bits(value), order)
    return ok(true)
}

// ---- appends ----

pub fn append_u8(data: Bytes, value: u8) {
    append_pattern(data, 1, value as u64, ByteOrder.little)
}

pub fn append_i8(data: Bytes, value: i8) {
    append_pattern(data, 1, (value as u8) as u64, ByteOrder.little)
}

pub fn append_u16(data: Bytes, value: u16, order: ByteOrder) {
    append_pattern(data, 2, value as u64, order)
}

pub fn append_i16(data: Bytes, value: i16, order: ByteOrder) {
    append_pattern(data, 2, (value as u16) as u64, order)
}

pub fn append_u32(data: Bytes, value: u32, order: ByteOrder) {
    append_pattern(data, 4, value as u64, order)
}

pub fn append_i32(data: Bytes, value: i32, order: ByteOrder) {
    append_pattern(data, 4, (value as u32) as u64, order)
}

pub fn append_u64(data: Bytes, value: u64, order: ByteOrder) {
    append_pattern(data, 8, value, order)
}

pub fn append_i64(data: Bytes, value: i64, order: ByteOrder) {
    append_pattern(data, 8, value as u64, order)
}

pub fn append_f32(data: Bytes, value: f32, order: ByteOrder) {
    append_pattern(data, 4, f32_bits(value), order)
}

pub fn append_f64(data: Bytes, value: float, order: ByteOrder) {
    append_pattern(data, 8, f64_bits(value), order)
}

// ---- varints ----

/// An unsigned varint read: the decoded value and how many bytes it took.
pub struct Uvarint {
    pub value: u64
    pub size: int
}

/// A signed zigzag varint read: the decoded value and how many bytes it took.
pub struct Varint {
    pub value: int
    pub size: int
}

/// Bytes needed to encode `value` as an unsigned LEB128 varint (1..=10).
pub fn uvarint_size(value: u64) -> int {
    var remaining: u64 = value
    var size: int = 1
    for remaining >= 128 {
        remaining = remaining >> 7
        size += 1
    }
    return size
}

/// Bytes needed to encode `value` as a signed zigzag varint.
pub fn varint_size(value: int) -> int {
    return uvarint_size(zigzag(value))
}

pub fn append_uvarint(data: Bytes, value: u64) {
    var remaining: u64 = value
    for remaining >= 128 {
        data.push(((remaining & 0x7f) | 0x80) as int)
        remaining = remaining >> 7
    }
    data.push(remaining as int)
}

/// Decodes an unsigned LEB128 varint at `pos`. Truncated input is kind
/// "eof"; a varint that runs past ten bytes or overflows 64 bits is kind
/// "overflow", matching the boundary Go's binary.Uvarint reports as n < 0.
pub fn read_uvarint(data: Bytes, pos: int) -> Result<Uvarint> {
    if pos < 0 || pos > data.len() {
        return err("uvarint read at {pos} is outside length {data.len()}", "eof")
    }
    var result: u64 = 0
    var shift: u64 = 0
    var index: int = pos
    for true {
        if index >= data.len() {
            return err("uvarint at {pos} is truncated at length {data.len()}", "eof")
        }
        if index - pos >= 10 {
            return err("uvarint at {pos} runs past 10 bytes", "overflow")
        }
        let piece: u64 = data.get(index) as u64
        if shift == 63 && (piece & 0xfe) != 0 {
            return err("uvarint at {pos} overflows 64 bits", "overflow")
        }
        result = result | ((piece & 0x7f) << shift)
        index += 1
        if (piece & 0x80) == 0 {
            return ok(Uvarint { value: result, size: index - pos })
        }
        shift += 7
    }
    return err("uvarint at {pos} is truncated", "eof")
}

fn zigzag(value: int) -> u64 {
    return ((value << 1) ^ (value >> 63)) as u64
}

fn unzigzag(pattern: u64) -> int {
    return ((pattern >> 1) ^ (0 - (pattern & 1))) as int
}

pub fn append_varint(data: Bytes, value: int) {
    append_uvarint(data, zigzag(value))
}

pub fn read_varint(data: Bytes, pos: int) -> Result<Varint> {
    let raw: Uvarint = read_uvarint(data, pos)?
    return ok(Varint { value: unzigzag(raw.value), size: raw.size })
}

// ---- cursors ----
//
// Bytes is a move-only buffer, so the cursors do not own one: every method
// borrows the buffer for the duration of the call and only the position
// lives in the cursor. This keeps a Reader usable beside every other use of
// the same buffer, with no clone and no ownership transfer.

pub class Reader {
    pub position: int = 0
    order: ByteOrder

    pub fn init(order: ByteOrder) {
        self.order = order
    }

    pub fn remaining(data: Bytes) -> int {
        let left: int = data.len() - self.position
        return if left < 0 { 0 } else { left }
    }

    pub fn skip(data: Bytes, count: int) -> Result<bool> {
        if count < 0 {
            return err("skip of {count} bytes is negative", "range")
        }
        check_range(data, self.position, count, "skip")?
        self.position += count
        return ok(true)
    }

    pub fn read_u8(data: Bytes) -> Result<u8> {
        let value: u8 = read_u8(data, self.position)?
        self.position += 1
        return ok(value)
    }

    pub fn read_i8(data: Bytes) -> Result<i8> {
        let value: i8 = read_i8(data, self.position)?
        self.position += 1
        return ok(value)
    }

    pub fn read_u16(data: Bytes) -> Result<u16> {
        let value: u16 = read_u16(data, self.position, self.order)?
        self.position += 2
        return ok(value)
    }

    pub fn read_i16(data: Bytes) -> Result<i16> {
        let value: i16 = read_i16(data, self.position, self.order)?
        self.position += 2
        return ok(value)
    }

    pub fn read_u32(data: Bytes) -> Result<u32> {
        let value: u32 = read_u32(data, self.position, self.order)?
        self.position += 4
        return ok(value)
    }

    pub fn read_i32(data: Bytes) -> Result<i32> {
        let value: i32 = read_i32(data, self.position, self.order)?
        self.position += 4
        return ok(value)
    }

    pub fn read_u64(data: Bytes) -> Result<u64> {
        let value: u64 = read_u64(data, self.position, self.order)?
        self.position += 8
        return ok(value)
    }

    pub fn read_i64(data: Bytes) -> Result<i64> {
        let value: i64 = read_i64(data, self.position, self.order)?
        self.position += 8
        return ok(value)
    }

    pub fn read_f32(data: Bytes) -> Result<f32> {
        let value: f32 = read_f32(data, self.position, self.order)?
        self.position += 4
        return ok(value)
    }

    pub fn read_f64(data: Bytes) -> Result<float> {
        let value: float = read_f64(data, self.position, self.order)?
        self.position += 8
        return ok(value)
    }

    pub fn read_uvarint(data: Bytes) -> Result<u64> {
        let raw: Uvarint = read_uvarint(data, self.position)?
        self.position += raw.size
        return ok(raw.value)
    }

    pub fn read_varint(data: Bytes) -> Result<int> {
        let raw: Varint = read_varint(data, self.position)?
        self.position += raw.size
        return ok(raw.value)
    }
}

pub class Writer {
    pub position: int = 0
    order: ByteOrder

    pub fn init(order: ByteOrder) {
        self.order = order
    }

    pub fn remaining(data: Bytes) -> int {
        let left: int = data.len() - self.position
        return if left < 0 { 0 } else { left }
    }

    pub fn write_u8(data: Bytes, value: u8) -> Result<bool> {
        write_u8(data, self.position, value)?
        self.position += 1
        return ok(true)
    }

    pub fn write_i8(data: Bytes, value: i8) -> Result<bool> {
        write_i8(data, self.position, value)?
        self.position += 1
        return ok(true)
    }

    pub fn write_u16(data: Bytes, value: u16) -> Result<bool> {
        write_u16(data, self.position, value, self.order)?
        self.position += 2
        return ok(true)
    }

    pub fn write_i16(data: Bytes, value: i16) -> Result<bool> {
        write_i16(data, self.position, value, self.order)?
        self.position += 2
        return ok(true)
    }

    pub fn write_u32(data: Bytes, value: u32) -> Result<bool> {
        write_u32(data, self.position, value, self.order)?
        self.position += 4
        return ok(true)
    }

    pub fn write_i32(data: Bytes, value: i32) -> Result<bool> {
        write_i32(data, self.position, value, self.order)?
        self.position += 4
        return ok(true)
    }

    pub fn write_u64(data: Bytes, value: u64) -> Result<bool> {
        write_u64(data, self.position, value, self.order)?
        self.position += 8
        return ok(true)
    }

    pub fn write_i64(data: Bytes, value: i64) -> Result<bool> {
        write_i64(data, self.position, value, self.order)?
        self.position += 8
        return ok(true)
    }

    pub fn write_f32(data: Bytes, value: f32) -> Result<bool> {
        write_f32(data, self.position, value, self.order)?
        self.position += 4
        return ok(true)
    }

    pub fn write_f64(data: Bytes, value: float) -> Result<bool> {
        write_f64(data, self.position, value, self.order)?
        self.position += 8
        return ok(true)
    }
}

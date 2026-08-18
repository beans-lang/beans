// size_of / align_of / offset_of — compile-time layout facts for the selected
// target. `beansc build --target <triple>` reports that target's numbers, not
// the compiler host's, which is why these are folded by the checker rather than
// asked of the machine at run time.

import std.io

extern "C" struct Packet {
    tag: u8
    count: u32
    ratio: f32
}

extern "C" struct Nested {
    head: Packet
    lanes: [u16; 3]
    tail: u64
}

extern "C" union Word {
    bits: u32
    number: f32
}

struct Plain {
    a: i16
    b: i64
}

fn main() {
    io.println("-- primitives --")
    io.println("i8    {size_of(i8)}/{align_of(i8)}")
    io.println("i16   {size_of(i16)}/{align_of(i16)}")
    io.println("i32   {size_of(i32)}/{align_of(i32)}")
    io.println("int   {size_of(int)}/{align_of(int)}")
    io.println("u64   {size_of(u64)}/{align_of(u64)}")
    io.println("f32   {size_of(f32)}/{align_of(f32)}")
    io.println("f64   {size_of(f64)}/{align_of(f64)}")
    io.println("bool  {size_of(bool)}/{align_of(bool)}")

    io.println("-- pointers and views --")
    io.println("RawPtr<u8>    {size_of(RawPtr<u8>)}/{align_of(RawPtr<u8>)}")
    io.println("RawPtr<Packet> {size_of(RawPtr<Packet>)}/{align_of(RawPtr<Packet>)}")
    io.println("Slice<u8>     {size_of(Slice<u8>)}/{align_of(Slice<u8>)}")
    // A class reference is one pointer. The object behind it is a heap
    // allocation with an ARC header, which is a different question.
    io.println("string        {size_of(string)}/{align_of(string)}")

    io.println("-- fixed arrays --")
    io.println("[u8; 7]    {size_of([u8; 7])}/{align_of([u8; 7])}")
    io.println("[u32; 4]   {size_of([u32; 4])}/{align_of([u32; 4])}")
    io.println("[[u16; 2]; 3] {size_of([[u16; 2]; 3])}/{align_of([[u16; 2]; 3])}")

    io.println("-- C records --")
    io.println("Packet {size_of(Packet)}/{align_of(Packet)}")
    io.println("Packet.tag   at {offset_of(Packet, tag)}")
    io.println("Packet.count at {offset_of(Packet, count)}")
    io.println("Packet.ratio at {offset_of(Packet, ratio)}")
    io.println("Nested {size_of(Nested)}/{align_of(Nested)}")
    io.println("Nested.head  at {offset_of(Nested, head)}")
    io.println("Nested.lanes at {offset_of(Nested, lanes)}")
    io.println("Nested.tail  at {offset_of(Nested, tail)}")
    io.println("Word {size_of(Word)}/{align_of(Word)}")
    io.println("Word.bits   at {offset_of(Word, bits)}")
    io.println("Word.number at {offset_of(Word, number)}")

    io.println("-- ordinary structs and SIMD --")
    io.println("Plain {size_of(Plain)}/{align_of(Plain)}")
    io.println("Plain.a at {offset_of(Plain, a)}")
    io.println("Plain.b at {offset_of(Plain, b)}")
    io.println("decimal {size_of(decimal)}/{align_of(decimal)}")
    io.println("Simd4f32 {size_of(Simd4f32)}/{align_of(Simd4f32)}")

    io.println("-- they are ordinary int constants --")
    let stride: int = size_of(Packet)
    var total: int = 0
    for i: int in 0..4 {
        total = total + stride
    }
    io.println("four packets span {total} bytes")
    if size_of(Nested) >= size_of(Packet) {
        io.println("Nested is at least as large as Packet")
    }
}

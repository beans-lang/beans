// The Beans half of the layout cross-check. test/fixtures/layout_reference.c
// prints byte-identical text using C's sizeof/alignof/offsetof, so Clang -- not
// the other Beans backend -- is the authority the numbers are checked against.
// Both backends being wrong the same way is the failure mode this catches.

import std.io

extern "C" struct Packet {
    tag: u8
    count: u32
    ratio: f32
}

extern "C" struct Mixed {
    flag: bool
    wide: u64
    small: i16
}

extern "C" struct Lanes {
    values: [u32; 4]
    tail: u8
}

extern "C" struct Nested {
    head: Packet
    lanes: [u16; 3]
    tail: u64
}

extern "C" struct Deep {
    outer: Nested
    pointer: RawPtr<u8>
    edge: i8
}

extern "C" union Word {
    bits: u32
    number: f32
}

extern "C" union Wide {
    small: u8
    big: u64
    pair: [u32; 2]
}

fn main() {
    io.println("i8 {size_of(i8)} {align_of(i8)}")
    io.println("i16 {size_of(i16)} {align_of(i16)}")
    io.println("i32 {size_of(i32)} {align_of(i32)}")
    io.println("i64 {size_of(i64)} {align_of(i64)}")
    io.println("u8 {size_of(u8)} {align_of(u8)}")
    io.println("u16 {size_of(u16)} {align_of(u16)}")
    io.println("u32 {size_of(u32)} {align_of(u32)}")
    io.println("u64 {size_of(u64)} {align_of(u64)}")
    io.println("f32 {size_of(f32)} {align_of(f32)}")
    io.println("f64 {size_of(f64)} {align_of(f64)}")
    io.println("bool {size_of(bool)} {align_of(bool)}")
    io.println("ptr {size_of(RawPtr<u8>)} {align_of(RawPtr<u8>)}")

    io.println("array_u8_7 {size_of([u8; 7])} {align_of([u8; 7])}")
    io.println("array_u32_4 {size_of([u32; 4])} {align_of([u32; 4])}")
    io.println("array_u16_2_3 {size_of([[u16; 2]; 3])} {align_of([[u16; 2]; 3])}")

    io.println("Packet {size_of(Packet)} {align_of(Packet)}")
    io.println("Packet.tag {offset_of(Packet, tag)}")
    io.println("Packet.count {offset_of(Packet, count)}")
    io.println("Packet.ratio {offset_of(Packet, ratio)}")

    io.println("Mixed {size_of(Mixed)} {align_of(Mixed)}")
    io.println("Mixed.flag {offset_of(Mixed, flag)}")
    io.println("Mixed.wide {offset_of(Mixed, wide)}")
    io.println("Mixed.small {offset_of(Mixed, small)}")

    io.println("Lanes {size_of(Lanes)} {align_of(Lanes)}")
    io.println("Lanes.values {offset_of(Lanes, values)}")
    io.println("Lanes.tail {offset_of(Lanes, tail)}")

    io.println("Nested {size_of(Nested)} {align_of(Nested)}")
    io.println("Nested.head {offset_of(Nested, head)}")
    io.println("Nested.lanes {offset_of(Nested, lanes)}")
    io.println("Nested.tail {offset_of(Nested, tail)}")

    io.println("Deep {size_of(Deep)} {align_of(Deep)}")
    io.println("Deep.outer {offset_of(Deep, outer)}")
    io.println("Deep.pointer {offset_of(Deep, pointer)}")
    io.println("Deep.edge {offset_of(Deep, edge)}")

    io.println("Word {size_of(Word)} {align_of(Word)}")
    io.println("Word.bits {offset_of(Word, bits)}")
    io.println("Word.number {offset_of(Word, number)}")

    io.println("Wide {size_of(Wide)} {align_of(Wide)}")
    io.println("Wide.small {offset_of(Wide, small)}")
    io.println("Wide.big {offset_of(Wide, big)}")
    io.println("Wide.pair {offset_of(Wide, pair)}")
}

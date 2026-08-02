// The Beans half of the packed/aligned layout cross-check.
// test/fixtures/packed_reference.c prints byte-identical text from C's
// sizeof/alignof/offsetof over the same declarations, so Clang -- not the other
// Beans backend -- is the authority. Two backends sharing one wrong assumption
// is the failure mode this catches, and for `packed` the wrong answer is a
// silently misplaced field rather than a crash.

import std.io

extern "C" packed struct Packed {
    tag: u8
    count: u32
    flag: bool
    value: u64
}

extern "C" align(64) struct Cacheline {
    seq: u32
    data: [u8; 56]
}

// An over-aligned record used as a field: its offset has to be a multiple of
// its declared alignment, which is the case LLVM's own struct layout cannot
// express and codegen has to pad explicitly.
extern "C" struct Holder {
    head: u8
    line: Cacheline
    tail: u8
}

extern "C" struct FieldAligned {
    a: u8
    align(16) b: u32
    c: u8
}

// A packed record nested inside another packed record.
extern "C" packed struct PackedNest {
    lead: u8
    inner: Packed
    trail: u16
}

extern "C" packed union PackedUnion {
    word: u64
    bytes: [u8; 3]
}

extern "C" align(32) union AlignedUnion {
    word: u64
    half: u32
}

fn main() {
    io.println("Packed {size_of(Packed)} {align_of(Packed)}")
    io.println("Packed.tag {offset_of(Packed, tag)}")
    io.println("Packed.count {offset_of(Packed, count)}")
    io.println("Packed.flag {offset_of(Packed, flag)}")
    io.println("Packed.value {offset_of(Packed, value)}")

    io.println("Cacheline {size_of(Cacheline)} {align_of(Cacheline)}")
    io.println("Cacheline.seq {offset_of(Cacheline, seq)}")
    io.println("Cacheline.data {offset_of(Cacheline, data)}")

    io.println("Holder {size_of(Holder)} {align_of(Holder)}")
    io.println("Holder.head {offset_of(Holder, head)}")
    io.println("Holder.line {offset_of(Holder, line)}")
    io.println("Holder.tail {offset_of(Holder, tail)}")

    io.println("FieldAligned {size_of(FieldAligned)} {align_of(FieldAligned)}")
    io.println("FieldAligned.a {offset_of(FieldAligned, a)}")
    io.println("FieldAligned.b {offset_of(FieldAligned, b)}")
    io.println("FieldAligned.c {offset_of(FieldAligned, c)}")

    io.println("PackedNest {size_of(PackedNest)} {align_of(PackedNest)}")
    io.println("PackedNest.lead {offset_of(PackedNest, lead)}")
    io.println("PackedNest.inner {offset_of(PackedNest, inner)}")
    io.println("PackedNest.trail {offset_of(PackedNest, trail)}")

    io.println("PackedUnion {size_of(PackedUnion)} {align_of(PackedUnion)}")
    io.println("PackedUnion.word {offset_of(PackedUnion, word)}")
    io.println("PackedUnion.bytes {offset_of(PackedUnion, bytes)}")

    io.println("AlignedUnion {size_of(AlignedUnion)} {align_of(AlignedUnion)}")
    io.println("AlignedUnion.word {offset_of(AlignedUnion, word)}")
    io.println("AlignedUnion.half {offset_of(AlignedUnion, half)}")
}

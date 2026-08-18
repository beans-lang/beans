// Packed and over-aligned records crossing the C ABI by value.
//
// The layout assertions check the numbers Beans reports. This checks the bytes:
// Clang lays the C side out from its own declaration, Beans from its own rules,
// and the values only survive the call if every offset agrees. A one-byte
// disagreement here is a wrong number in the output, not a crash, which is why
// it has to be an executed test rather than a compile-time one.

import std.io

extern "C" packed struct PackedHeader {
    tag: u8
    count: u32
    flag: bool
    value: u64
}

// Small enough to write as a literal; the declared alignment is what makes it
// 64 bytes, which is the padding path being tested.
extern "C" align(64) struct Cacheline {
    seq: u32
    data: [u8; 12]
}

extern "C" fn beans_test_packed_sum(header: PackedHeader) -> u64
extern "C" fn beans_test_packed_make(tag: u8, count: u32, value: u64) -> PackedHeader
extern "C" fn beans_test_misalign(p: RawPtr<Cacheline>, mask: u64) -> u64
extern "C" fn beans_test_cacheline_seq(line: RawPtr<Cacheline>) -> u64
extern "C" fn beans_test_cacheline_tail(line: RawPtr<Cacheline>) -> u64
extern "C" fn beans_test_packed_sizes() -> u64

fn main() {
    // Sizes agreed on both sides of the boundary. C returns them as one number
    // so a single call pins both.
    io.println("beans sizes {size_of(PackedHeader)} {size_of(Cacheline)}")
    unsafe {
        io.println("c sizes {beans_test_packed_sizes()}")
    }

    // Beans builds it, C reads every field.
    let header: PackedHeader =
        PackedHeader { tag: 7, count: 70000, flag: true, value: 900000000000 }
    unsafe {
        io.println("sum {beans_test_packed_sum(header)}")
    }

    // C builds it, Beans reads every field back.
    unsafe {
        let back: PackedHeader = beans_test_packed_make(9, 123456, 5000000000)
        io.println("back {back.tag} {back.count} {back.flag} {back.value}")
    }

    // An over-aligned record written by Beans and read by C. `data` sits at 4
    // and the record is 64 bytes long; getting either wrong changes the answer.
    // element_size/element_align come from the interpreter's own raw view, so
    // this also pins that third layout engine to the same numbers.
    unsafe {
        let line: RawPtr<Cacheline> = RawPtr.alloc(1)
        var value: Cacheline = Cacheline {
            seq: 42,
            data: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 200]
        }
        line.write(value)
        io.println("element {line.element_size()} {line.element_align()}")
        // C reports the low six bits of the address it was handed. `alloc` asks
        // for the element's own alignment, so an align(64) record must land on a
        // 64-byte boundary -- malloc alone only promises 16.
        io.println("misalign {beans_test_misalign(line, 63)}")
        io.println("seq {beans_test_cacheline_seq(line)}")
        io.println("tail {beans_test_cacheline_tail(line)}")
        line.free()

        // A stricter alignment than the element needs, asked for explicitly.
        let page: RawPtr<Cacheline> = RawPtr.alloc_aligned(2, 256)
        page.write(value)
        io.println("page misalign {beans_test_misalign(page, 255)}")
        io.println("page seq {beans_test_cacheline_seq(page)}")
        page.free()
    }
}

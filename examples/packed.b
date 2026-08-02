// Packed and over-aligned layouts.
//
// `packed` drops every byte of padding between fields, which is what a wire
// format or an on-disk header needs. `align(N)` does the opposite: it raises a
// record's alignment, and therefore its size, so a value can be given a cache
// line of its own. Both are only allowed on `extern "C"` structs and unions,
// because they only mean something against a fixed byte layout.

import std.io

// A wire header. Unpacked this would be 16 bytes with two holes; packed it is
// exactly the 11 bytes that go on the wire.
extern "C" packed struct Header {
    kind: u8
    length: u32
    flags: u16
    checksum: u32
}

// Packing composes: a packed record nested inside another packed record adds no
// padding either.
extern "C" packed struct Frame {
    lead: u8
    header: Header
    trailer: u16
}

// The other direction. Four bytes of payload, one whole cache line of space, so
// two of these can never share a line.
extern "C" align(64) struct Counter {
    hits: u32
}

// An over-aligned record used as a field: `second` has to land on the next
// multiple of 64, not straight after `first`.
extern "C" struct Pair {
    first: Counter
    second: Counter
}

// A single field can be raised on its own, without packing anything.
extern "C" struct Slot {
    tag: u8
    align(16) payload: u64
}

fn main() {
    io.println("Header {size_of(Header)}/{align_of(Header)}")
    io.println("Header.kind at {offset_of(Header, kind)}")
    io.println("Header.length at {offset_of(Header, length)}")
    io.println("Header.flags at {offset_of(Header, flags)}")
    io.println("Header.checksum at {offset_of(Header, checksum)}")

    io.println("Frame {size_of(Frame)}/{align_of(Frame)}")
    io.println("Frame.header at {offset_of(Frame, header)}")
    io.println("Frame.trailer at {offset_of(Frame, trailer)}")

    io.println("Counter {size_of(Counter)}/{align_of(Counter)}")
    io.println("Pair {size_of(Pair)}/{align_of(Pair)}")
    io.println("Pair.second at {offset_of(Pair, second)}")

    io.println("Slot {size_of(Slot)}/{align_of(Slot)}")
    io.println("Slot.payload at {offset_of(Slot, payload)}")

    // Packed fields read and write like any others. The compiler knows they may
    // sit at an unaligned address and emits the accesses accordingly.
    var header: Header = Header { kind: 3, length: 1024, flags: 5, checksum: 0 }
    header.length += 1
    header.checksum = 4275878552
    io.println("header {header.kind} {header.length} {header.flags} {header.checksum}")

    let frame: Frame = Frame { lead: 255, header: header, trailer: 513 }
    io.println("frame {frame.lead} {frame.header.length} {frame.trailer}")

    // Copies are by value, and equality is field by field, padding excluded.
    var other: Header = header
    other.flags = 6
    io.println("copy {header.flags} {other.flags} eq {header == other}")

    let counters: Pair = Pair { first: Counter { hits: 1 }, second: Counter { hits: 2 } }
    io.println("pair {counters.first.hits} {counters.second.hits}")

    // The bytes really are contiguous: writing a packed record to raw memory and
    // reading the following field back proves nothing was padded.
    unsafe {
        let memory: RawPtr<Header> = RawPtr.alloc(2)
        memory.write(header)
        memory.offset(1).write(other)
        io.println("raw stride {memory.element_size()}/{memory.element_align()}")
        let second: Header = memory.offset(1).read()
        io.println("raw second {second.kind} {second.length} {second.flags}")

        // Byte 5 of the second record is the low byte of its `flags`, which only
        // holds if `flags` sits at offset 5 with no padding in front of it.
        let bytes: RawPtr<u8> = RawPtr.from_address(memory.address())
        let at: int = size_of(Header) + offset_of(Header, flags)
        io.println("byte {at} is {bytes.offset(at).read()}")
        memory.free()

        // `alloc` gives the element type's own alignment. malloc only promises
        // 16, so an align(64) record needs more than plain malloc to sit where
        // align_of says it does.
        let counters: RawPtr<Counter> = RawPtr.alloc(4)
        io.println("counter storage {counters.element_align()} aligned {counters.address() % 64 == 0}")
        counters.free()

        // A stricter alignment can be asked for directly. It must be a power of
        // two and at least the element's own, or the allocation panics rather
        // than quietly handing back something weaker.
        let page: RawPtr<Counter> = RawPtr.alloc_aligned(2, 4096)
        io.println("page aligned {page.address() % 4096 == 0}")
        page.free()
    }
}

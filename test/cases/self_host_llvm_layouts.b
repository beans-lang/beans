import std.io

extern "C" packed struct Header {
    tag: u8
    value: u32
}

extern "C" align(64) struct Counter {
    value: u32
}

extern "C" struct Pair {
    first: Counter
    second: Counter
}

extern "C" struct Slot {
    tag: u8
    align(16) value: u64
}

fn main() {
    io.println("scalar {size_of(u16)}/{align_of(u16)}")
    io.println("header {size_of(Header)}/{align_of(Header)} {offset_of(Header, value)}")
    io.println("pair {size_of(Pair)}/{align_of(Pair)} {offset_of(Pair, second)}")
    io.println("slot {size_of(Slot)}/{align_of(Slot)} {offset_of(Slot, value)}")

    var header: Header = Header { tag: 3, value: 40 }
    header.value += 2
    let pair: Pair = Pair {
        first: Counter { value: 1 },
        second: Counter { value: 2 },
    }
    io.println("values {header.tag} {header.value} {pair.second.value}")
}

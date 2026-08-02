import std.io

extern "C" struct Packet {
    tag: u8
    count: u32
}

fn main() {
    io.println("{offset_of(Packet, nope)}")
}

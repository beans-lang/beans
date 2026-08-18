// A struct without extern "C" makes no layout promise, so it cannot be packed.
packed struct Wrong {
    a: u8
    b: u32
}

fn main() {
}

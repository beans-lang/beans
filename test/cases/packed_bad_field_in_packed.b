// packed already fixes every offset, so a field alignment would contradict it.
extern "C" packed struct Wrong {
    a: u8
    align(8) b: u32
}

fn main() {
}

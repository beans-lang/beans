// Alignment has to be a power of two.
extern "C" align(24) struct Wrong {
    a: u32
}

fn main() {
}

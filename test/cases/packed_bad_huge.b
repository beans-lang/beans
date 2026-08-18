// Past what the target can align to.
extern "C" align(8192) struct Wrong {
    a: u32
}

fn main() {
}

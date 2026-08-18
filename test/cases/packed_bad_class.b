// `packed` needs a fixed byte layout, and only extern "C" records have one.
packed class Wrong {
    a: u8
}

fn main() {
}

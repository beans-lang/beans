import std.io

struct Loop {
    next: Loop
}

fn main() {
    io.println("{size_of(Loop)}")
}

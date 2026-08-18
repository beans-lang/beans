import std.io

enum Status {
    active
    closed
}

fn main() {
    io.println("{size_of(Status)}")
    io.println("{size_of(Option<int>)}")
}

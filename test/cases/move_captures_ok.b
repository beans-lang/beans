import std.io

unique class Handle {
    id: int = 0
    fn deinit() { io.println("closed {self.id}") }
}

fn make_owner(tag: int) -> fn() -> int {
    var h: Handle = new Handle()
    h.id = tag
    let owner: fn() -> int = fn() move(h) -> int {
        return h.id * 2
    }
    io.println("made {tag}")
    return owner
}

fn spend_list() -> fn() -> int {
    var xs: List<int> = [1, 2, 3]
    return fn() move(xs) -> int {
        return xs.len()
    }
}

fn main() {
    let f: fn() -> int = make_owner(21)
    io.println("call {f()}")
    io.println("again {f()}")
    let g: fn() -> int = spend_list()
    io.println("list {g()}")
    io.println("end")
}

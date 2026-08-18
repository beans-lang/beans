import std.io

unique class Handle {
    id: int = 0
}

fn use_after() {
    let h: Handle = new Handle()
    let f: fn() -> int = fn() move(h) -> int { return h.id }
    io.println("{h.id}")
}

fn unknown_name() {
    let f: fn() -> int = fn() move(ghost) -> int { return 1 }
}

fn unused_capture() {
    let h: Handle = new Handle()
    let f: fn() -> int = fn() move(h) -> int { return 3 }
}

fn double_listed() {
    let h: Handle = new Handle()
    let f: fn() -> int = fn() move(h, h) -> int { return h.id }
}

fn main() {}

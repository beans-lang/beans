package main

import std.io
import std.thread

fn add_one(value: int) -> int {
    return value + 1
}

fn main() {
    let bytes: Bytes = Bytes.from("beans")
    let work: send fn() -> int =
        fn() move(bytes) -> int { return bytes.len() }
    let first: Thread<int> = thread.spawn(move work)
    io.println("{first.join()}")

    let named: send fn(int) -> int = add_one
    let second: Thread<int> = thread.spawn(
        fn() move(named) -> int { return named(41) })
    io.println("{second.join()}")

    let local: fn(int) -> int =
        fn(value: int) -> int { return value * 2 }
    io.println("{local(21)}")
}

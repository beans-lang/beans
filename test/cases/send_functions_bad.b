package main

import std.thread

class Local {
    value: int = 0
}

fn non_send_capture() {
    let local: Local = new Local()
    let work: send fn() = fn() { local.value += 1 }
}

fn mutable_alias() {
    var count: int = 0
    let work: send fn() = fn() { count += 1 }
}

fn ordinary_value() {
    let work: fn() -> int = fn() -> int { return 1 }
    thread.spawn(work)
}

fn copied_send_value() {
    let work: send fn() -> int = fn() -> int { return 1 }
    let copy: send fn() -> int = work
}

fn cloned_send_value() {
    let work: send fn() -> int = fn() -> int { return 1 }
    let copy: send fn() -> int = work.clone()
}

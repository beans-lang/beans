package main

import std.encoding.json
import std.io
import std.thread

struct Wide {
    pub name: string
    pub count: int
    pub tags: List<string>
}

struct Narrow {
    pub id: int
    pub ok: bool
}

fn worker(rounds: int) -> int {
    var bad: int = 0
    for round: int in 0..rounds {
        match json.encode(Wide {
            name: "worker-{round}",
            count: round,
            tags: ["alpha", "beta"],
        }) {
            ok(_) => {}
            err(_) => { bad += 1 }
        }
        match json.encode(Narrow { id: round, ok: round % 2 == 0 }) {
            ok(_) => {}
            err(_) => { bad += 1 }
        }
    }
    return bad
}

fn main() {
    var crew: List<Thread<int>> = []
    for index: int in 0..4 {
        crew.push(thread.spawn(fn() -> int { return worker(20000) }))
    }
    var bad: int = 0
    for index: int in 0..4 {
        let handle: Thread<int> = crew.pop().expect("worker handle")
        bad += handle.join()
    }
    io.println("concurrent encode workers finished bad {bad}")
}

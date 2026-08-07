package main

import std.io

class Counter {
    total: int
    label: string

    fn init(label: string) {
        self.total = 0
        self.label = label
    }

    fn bump(by: int) -> int {
        self.total = self.total + by
        return self.total
    }
}

fn double(value: int) -> int {
    let doubled: int = value * 2
    return doubled
}

fn main() {
    let counter: Counter = new Counter("hits")
    var running: int = 0
    let numbers: List<int> = [3, 5, 8]
    for item: int in numbers {
        running = counter.bump(item)
    }
    let scaled: int = double(running)
    io.println("total {running} scaled {scaled}")
}

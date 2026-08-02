import std.io

struct Entry {
    name: string
    score: int
}

struct Pair {
    a: i32
    b: i32
}

fn main() {
    var entries: List<Entry> = []
    entries.push(Entry { name: "one", score: 1 })
    entries.push(Entry { name: "two", score: 2 })
    let extra: Entry = Entry { name: "kept", score: 3 }
    entries.push(extra)
    io.println(entries.len())
    io.println("{entries[0].name}:{entries[0].score}")
    io.println("{extra.name}:{extra.score}")

    entries[1] = Entry { name: "swap", score: 20 }
    var total: int = 0
    for e: Entry in entries {
        total += e.score
        io.println("{e.name}={e.score}")
    }
    io.println(total)

    var small: List<Pair> = [Pair { a: 1, b: 2 }, Pair { a: 3, b: 4 }]
    io.println("{small[0].a},{small[1].b},{small.len()}")
}

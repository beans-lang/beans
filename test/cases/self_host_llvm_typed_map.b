import std.io

struct Entry {
    name: string
    score: int
}

fn main() {
    var by_key: Map<string, Entry> = {}
    by_key["one"] = Entry { name: "first", score: 1 }
    by_key["two"] = Entry { name: "second", score: 2 }
    by_key["one"] = Entry { name: "first2", score: 11 }
    io.println(by_key.len())
    io.println(by_key.contains("one"))
    io.println(by_key.contains("zero"))
    let found: Entry = by_key["one"]
    io.println("{found.name}:{found.score}")

    var by_id: Map<int, Entry> = {
        7: Entry { name: "seven", score: 70 },
    }
    io.println(by_id.insert(8, Entry { name: "eight", score: 80 }))
    io.println(by_id.insert(7, Entry { name: "again", score: 71 }))
    io.println("{by_id[7].name}:{by_id[8].score}")
    io.println(by_id.remove(8))
    io.println(by_id.len())
}

// the simple container rows: clear (death order is back to
// front, same as the interpreter's vector teardown), reverse,
// clone (an independent copy — mutating one side must not touch
// the other), Map.values, Map.clear, and List<decimal>.sort.
import std.io

class Tracer {
    name: string

    fn init(name: string) {
        self.name = name
    }

    fn deinit() {
        io.println("drop {self.name}")
    }
}

fn main() {
    var order: List<Tracer> = []
    order.push(new Tracer("first"))
    order.push(new Tracer("second"))
    order.push(new Tracer("third"))
    order.clear()
    io.println("cleared {order.len()}")

    var xs: List<int> = [1, 2, 3, 4]
    xs.reverse()
    io.println(xs)

    var names: List<string> = ["a", "b"]
    var copied: List<string> = names.clone()
    copied.push("c")
    io.println("{names} {copied}")

    var table: Map<string, int> = {}
    table["one"] = 1
    table["two"] = 2
    let seen: List<int> = table.values()
    io.println(seen)
    table.clear()
    io.println("emptied {table.len()}")

    var ds: List<decimal> = [2.50, 1.10, 3.25]
    ds.sort()
    io.println(ds)

    // comparator thunks rebuild elements from slots (narrow ints
    // truncate back), key thunks return one i64 per element, and
    // index_of answers Option<int> with a zero none-payload
    var scores: List<int> = [4, 1, 3, 2]
    let flip: bool = true
    scores.sort_by(fn(a: int, b: int) -> bool {
        if flip {
            return a > b
        }
        return a < b
    })
    io.println(scores)

    var words: List<string> = ["bbb", "a", "cc"]
    words.sort_by(fn(a: string, b: string) -> bool {
        return a.len() < b.len()
    })
    io.println(words)
    words.sort_by_key(fn(word: string) -> int {
        return 0 - word.len()
    })
    io.println(words)

    var tiny: List<i8> = [3 as i8, -1 as i8, 2 as i8]
    tiny.sort_by(fn(a: i8, b: i8) -> bool { return a > b })
    io.println("{tiny[0]} {tiny[1]} {tiny[2]}")

    let hay: List<int> = [10, 20, 30]
    io.println("{hay.index_of(20).or(-1)} {hay.index_of(7).or(-1)}")
    let straws: List<string> = ["x", "y"]
    io.println("{straws.index_of("y").or(-1)} {straws.index_of("z").or(-1)}")
}

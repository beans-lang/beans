import std.io

class Pair {
    left: int = 0
    right: int = 0
    name: string

    fn init(left: int, right: int, move name: string) {
        self.left = left
        self.right = right
        self.name = move name
    }

    fn total() -> int {
        return self.left + self.right
    }

    fn label() -> string {
        return self.name
    }

    static fn answer() -> int {
        return 42
    }
}

fn main() {
    var pair: Pair = new Pair(20, 22, "pair")
    var alias: Pair = pair
    var keep: List<Pair> = []
    keep.push(pair)
    io.println("{alias.label()} {pair.total()} {keep.len()}")
    io.println(Pair.answer())
}

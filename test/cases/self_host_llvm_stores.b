import std.io

class Tally {
    label: string
    total: int
    bits: int
    ratio: float

    fn init(label: string) {
        self.label = label
        self.total = 10
        self.bits = 12
        self.ratio = 8.0
    }

    fn mix(amount: int) {
        self.total += amount
        self.total -= 1
        self.total *= 3
        self.total /= 2
        self.total %= 100
        self.bits += 3
        self.bits *= 2
        self.ratio *= 2.5
        self.ratio /= 4.0
        self.ratio += 0.5
        self.ratio -= 1.0
    }
}

enum Mark {
    none_yet
    at(pos: int)
}

fn main() {
    let t: Tally = new Tally("acc")
    t.mix(7)
    io.println("{t.label}:{t.total}:{t.bits}:{t.ratio}")

    var xs: List<int> = []
    xs.push(1)
    xs.push(2)
    xs.push(3)
    xs[1] = 50
    xs[2] = xs[0] + xs[1]
    io.println("{xs[0]},{xs[1]},{xs[2]}")

    var names: List<string> = []
    names.push("a")
    names.push("b")
    names[0] = "left"
    let keep: string = "kept"
    names[1] = keep
    io.println("{names[0]},{names[1]},{keep}")

    var marks: List<Mark> = []
    marks.push(Mark.none_yet)
    marks.push(Mark.at(4))
    marks[0] = Mark.at(9)
    match marks[0] {
        at(pos) => { io.println("mark {pos}") },
        none_yet => { io.println("mark none") },
    }
}

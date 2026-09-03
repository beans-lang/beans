struct Pt {
    cells: [int; 2]
}

struct Label {
    text: string
    kind: int
}

class Bag {
    labels: [Label; 2]

    fn init() {
        self.labels = [
            Label { text: "a", kind: 1 },
            Label { text: "b", kind: 2 },
        ]
    }
}

class Shelf {
    static labels: [Label; 2] =
        [Label { text: "a", kind: 1 }, Label { text: "b", kind: 2 }]
}

fn make() -> Pt {
    return Pt { cells: [1, 2] }
}

fn main() {
    // a let's elements stay frozen even through a field
    let fixed: Pt = Pt { cells: [1, 2] }
    fixed.cells[0] = 9

    // a temporary copy would swallow the store
    make().cells[0] = 5

    // list elements are not writable places yet
    var rows: List<Pt> = [Pt { cells: [1, 2] }]
    rows[0].cells[1] = 7

    // owned references inside a class-held array need the write
    // barrier element stores do not emit yet
    let bag: Bag = new Bag()
    bag.labels[0] = Label { text: "x", kind: 3 }

    // a static is addressable storage like a heap object, and carries the
    // same open question for the same reason
    Shelf.labels[0] = Label { text: "y", kind: 4 }
}

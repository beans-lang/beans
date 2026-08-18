import std.io

struct Pair {
    left: int
    right: int
}

fn joined(left: string, right: string) -> string {
    return "{left}{right}"
}

fn main() {
    var plain: Map<string, int> = {
        "one": 1,
        "two": 2,
        "three": 3,
    }
    var sum: int = 0
    var names: List<string> = []
    for name: string, value: int in plain {
        names.push(name)
        sum += value
    }
    names.sort()
    io.println("plain {names.join(",")} {sum}")

    var ordered: OrderedMap<int, string> = {
        2: "two",
        1: "one",
        3: "three",
    }
    var order: string = ""
    for key: int, value: string in ordered {
        order = "{order}{key}:{value};"
    }
    io.println("ordered {order}")

    var wide: Map<Pair, Pair> = {
        Pair { left: 1, right: 2 }:
            Pair { left: 3, right: 4 },
        Pair { left: 5, right: 6 }:
            Pair { left: 7, right: 8 },
    }
    var wide_sum: int = 0
    for key: Pair, value: Pair in wide {
        wide_sum += key.left + key.right +
                    value.left + value.right
    }
    io.println("wide {wide_sum}")

    // Replacing a value does not move map storage. The current loop binding
    // remains its own copy, and later iterations see the replacement.
    var changed: OrderedMap<int, string> = {
        1: joined("old", "-one"),
        2: joined("old", "-two"),
    }
    var seen: string = ""
    for key: int, value: string in changed {
        if key == 1 {
            changed[1] = "replaced-one"
            changed[2] = "new-two"
        }
        seen = "{seen}{key}:{value};"
    }
    io.println("replace {seen}")
}

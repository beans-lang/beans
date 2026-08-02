import std.io

class TreeCounter {
    value: int

    fn init(start: int) {
        self.value = start
    }

    fn add(amount: int) -> int {
        self.value += amount
        return self.value
    }
}

fn tree_default(value: int) -> int {
    io.println("default {value}")
    return value
}

struct TreeDefaults {
    first: int = tree_default(1)
    second: int = tree_default(2)
}

class TreeDefaultClass {
    value: int = tree_default(4)
}

fn tree_sum(limit: int) -> int {
    var total: int = 0
    for value: int in 0..limit {
        total += value
    }
    return total
}

fn main() {
    let counter: TreeCounter = new TreeCounter(2)
    let current: int = counter.add(3)
    let total: int = tree_sum(5)
    var values: List<int> = [current]
    values.push(total)
    let chosen: int =
        if values.len() == 2 {
            values.get(1).or(0)
        } else {
            0
        }
    let defaults: TreeDefaults = TreeDefaults {
        first: tree_default(3)
    }
    let default_class: TreeDefaultClass =
        new TreeDefaultClass()
    let minimum: int = -9223372036854775808
    io.println(
        "tree {current} {total} {chosen} {values.len()} {defaults.first} {defaults.second} {default_class.value} {minimum}")
}

import std.io

struct Item {
    label: string
    value: int
}

fn item(number: int) -> Item {
    return Item {
        label: "item{number}",
        value: number,
    }
}

fn main() {
    var items: List<Item> = [item(1), item(2)]
    items.insert(1, item(3))
    let removed: Item = items.remove(0)
    let first: Item =
        items.first().or(item(0))
    let found: Item =
        items.get(1).or(item(0))
    let middle: List<Item> =
        items.slice(0, 1)

    var fixed: [Item; 2] =
        [item(4), item(5)]
    let copy: [Item; 2] = fixed
    fixed[0] = item(6)

    let decimals: List<decimal> =
        [2.50, 1.25, 2.5]
    io.println("wide {removed.label} {first.label} {found.label} {middle[0].label} {copy[0].label} {fixed[0].label} {decimals.min().or(0.0)} {decimals.max().or(0.0)} {decimals.contains(2.50)}")
}

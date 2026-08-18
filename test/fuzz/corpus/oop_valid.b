interface Labelled {
    fn label() -> string
}

abstract class Base {
    abstract fn value() -> int
}

class Item extends Base implements Labelled {
    static made: int = 0
    priv value_seed: int

    priv static fn record() { Item.made += 1 }
    priv fn seed() -> int { return self.value_seed }

    fn init(value_seed: int) {
        self.value_seed = value_seed
        Item.record()
    }

    override fn value() -> int { return self.seed() }
    fn label() -> string { return "item" }
}

singleton class Registry {
    priv total: int = 0

    priv fn add_to_total(value: int) { self.total += value }

    fn add(value: int) -> int {
        self.add_to_total(value)
        return self.total
    }
}

struct Cell<T> {
    value: T
    previous: Option<T> = none

    priv fn stored() -> T { return self.value }
    fn current() -> T { return self.stored() }
    priv inout fn store(value: T) { self.value = value }
    inout fn replace(value: T) { self.store(value) }
}

fn main() {
    let item: Base = new Item(7)
    var cell: Cell<int> = Cell { value: item.value() }
    cell.replace(9)
    Registry.instance.add(cell.current())
}

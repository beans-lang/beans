import std.io

class Base {
    value: int

    fn init(value: int) { self.value = value }
    fn read() -> int { return self.value }
}

class Child extends Base {
    label: string

    fn init(label: string, value: int) {
        self.label = label
        super.init(value)
    }
}

class Holder<T> {
    item: T

    fn init(item: T) { self.item = item }
}

fn make_child() -> Child {
    return new("return", 2)
}

fn read_base(value: Base) -> int {
    return value.read()
}

fn main() {
    let direct: Child = new ("direct", 1)
    let returned: Child = make_child()
    let holder: Holder<Child> = new(new("nested", 3))
    let bytes: Bytes = new(4)
    let boxed: Box<int> = new(7)
    let shared: Shared<string> = new("shared")
    let mutex: Mutex<int> = new(8)
    let arena: Arena<int> = new(2)
    let channel: Channel<int> = new(2)
    let atomic: Atomic<i32> = new(10)
    let atomic_int: AtomicInt = new(9)
    var assigned: Child = new("old", 4)
    assigned = new("assigned", 5)
    io.println("{direct.read()} {returned.label} {holder.item.read()} {bytes.len()} {assigned.read()} {read_base(new(6))}")
}

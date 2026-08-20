import std.thread

class Local {
    value: int = 1
}

unique class Parcel<T> implements Send {
    value: T

    fn init(move value: T) {
        self.value = move value
    }

    fn count() -> int { return 1 }
}

fn main() {
    let item: Local = new Local()
    let values: List<Local> = [item]
    let list_worker: Thread<int> = thread.spawn(
        fn() move(values) -> int { return values.len() })

    let box: Box<Local> = new Box(item)
    let box_worker: Thread<int> = thread.spawn(
        fn() move(box) -> int { return box.get().value })

    let arena: Arena<Local> = new Arena(1)
    arena.add(item)
    let arena_worker: Thread<int> = thread.spawn(
        fn() move(arena) -> int { return arena.len() })

    let table: Map<string, Local> = {"item": item}
    let map_worker: Thread<int> = thread.spawn(
        fn() move(table) -> int { return table.len() })

    let ordered: OrderedMap<string, Local> = {"item": item}
    let ordered_worker: Thread<int> = thread.spawn(
        fn() move(ordered) -> int { return ordered.len() })

    let parcel: Parcel<Local> = new Parcel(item)
    let parcel_worker: Thread<int> = thread.spawn(
        fn() move(parcel) -> int { return parcel.count() })
}

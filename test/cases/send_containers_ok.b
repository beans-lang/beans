import std.io
import std.thread

extern "C" union Word {
    bits: u32
    number: f32
}

unique class Parcel<T> implements Send {
    value: T

    fn init(move value: T) {
        self.value = move value
    }

    fn count() -> int { return 1 }
}

fn main() {
    let values: List<int> = [1, 2, 3]
    let list_worker: Thread<int> = thread.spawn(
        fn() move(values) -> int { return values.len() })

    let box: Box<int> = new Box(7)
    let box_worker: Thread<int> = thread.spawn(
        fn() move(box) -> int { return box.get() })

    let arena: Arena<int> = new Arena(1)
    let handle: int = arena.add(9)
    let arena_worker: Thread<int> = thread.spawn(
        fn() move(arena) -> int { return arena.at(handle) })

    let table: Map<string, int> = {"a": 1, "b": 2}
    let map_worker: Thread<int> = thread.spawn(
        fn() move(table) -> int { return table.len() })

    let ordered: OrderedMap<string, int> = {"a": 1, "b": 2}
    let ordered_worker: Thread<int> = thread.spawn(
        fn() move(ordered) -> int { return ordered.len() })

    var word: Word
    unsafe { word = Word { bits: 42 } }
    let union_worker: Thread<u32> = thread.spawn(fn() move(word) -> u32 {
        unsafe { return word.bits }
    })

    let parcel: Parcel<int> = new Parcel(1)
    let parcel_worker: Thread<int> = thread.spawn(
        fn() move(parcel) -> int { return parcel.count() })

    io.println("{list_worker.join()} {box_worker.join()} {arena_worker.join()} {map_worker.join()} {ordered_worker.join()} {union_worker.join()} {parcel_worker.join()}")
}

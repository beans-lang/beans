// A `Slice<T>` is a borrowed `{pointer, length}` view of memory something else
// owns. `for x: T in s` reads that memory live, one element at a time: a write
// to the memory the slice views -- made here through the pointer that owns it,
// while the loop runs -- is visible to the turns that have not run yet, and the
// slice's length cannot change so there is nothing to invalidate. Both backends
// agree: the native loop always loaded each element from memory as it went, and
// the interpreter now does too instead of snapshotting the view when the loop
// started. spec/SYNTAX.md, "Changing a collection while a loop reads it".
//
// (The write is through the owning `RawPtr`, not `view[i] = v`: writing through
// a slice is a separate emitter gap the native backend refuses, unrelated to
// how the loop reads.)
import std.io

// Overwrite, through the owning pointer, an element the loop has not reached
// yet. The loop reads memory live, so it must see 500.
fn write_ahead() -> string {
    unsafe {
        let storage: RawPtr<i32> = RawPtr.alloc(4)
        var i: int = 0
        for i < 4 {
            storage.offset(i).write((i + 1) as i32)
            i += 1
        }
        let view: Slice<i32> = Slice.from_raw(storage, 4)
        var seen: List<int> = []
        for x: i32 in view {
            seen.push(x as int)
            if seen.len() == 1 { storage.offset(3).write(500 as i32) }
        }
        storage.free()
        return seen.join(",")
    }
}

// A plain read pass sees the value the memory holds when each turn reaches it.
fn read_only() -> int {
    unsafe {
        let storage: RawPtr<i32> = RawPtr.alloc(3)
        storage.write(10)
        storage.offset(1).write(20)
        storage.offset(2).write(30)
        let view: Slice<i32> = Slice.from_raw(storage, 3)
        var total: int = 0
        for x: i32 in view { total += x as int }
        storage.free()
        return total
    }
}

fn main() {
    io.println("slice ahead: {write_ahead()}")
    io.println("slice total: {read_only()}")
}

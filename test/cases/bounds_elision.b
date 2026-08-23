import std.io

fn stable() -> int {
    unsafe {
        let storage: RawPtr<i32> = RawPtr.alloc(4)
        storage.write(1)
        storage.offset(1).write(2)
        storage.offset(2).write(3)
        storage.offset(3).write(4)
        let view: Slice<i32> = Slice.from_raw(storage, 4)
        var total: int = 0
        var index: int = 0
        for index < view.len() {
            total += view[index] as int
            index += 1
        }
        storage.free()
        return total
    }
}

fn negative_start(storage: RawPtr<i32>) -> int {
    unsafe {
        let view: Slice<i32> = Slice.from_raw(storage, 4)
        var total: int = 0
        var index: int = -1
        for index < view.len() {
            total += view[index] as int
            index += 1
        }
        return total
    }
}

fn increment_first(storage: RawPtr<i32>) -> int {
    unsafe {
        let view: Slice<i32> = Slice.from_raw(storage, 4)
        var total: int = 0
        var index: int = 0
        for index < view.len() {
            index += 1
            total += view[index] as int
        }
        return total
    }
}

// An `inout` argument lowers to a borrow of the counter. The callee may
// store anything behind it — including a negative index that still passes
// `index < view.len()` — so the counted-loop proof must not fire here.
fn reset_counter(inout value: int) { value = -8 }

fn borrowed_start(storage: RawPtr<i32>) -> int {
    unsafe {
        let view: Slice<i32> = Slice.from_raw(storage, 4)
        var total: int = 0
        var index: int = 0
        reset_counter(inout index)
        for index < view.len() {
            total += view[index] as int
            index += 1
        }
        return total
    }
}

fn main() {
    io.println(stable())
}

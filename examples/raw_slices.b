/*
Slice<T> — a borrowed {pointer, length} view over memory you already own.

What it is:
  An inline two-word view. It owns nothing and frees nothing. Build one with
  `Slice.from_raw(ptr, len)`, cut a smaller window with `subslice(start, end)`,
  read with `get`/`[]`, write with `set`, and hand the pointer back out with
  `as_ptr()`. Reads and writes are bounds checked, and a non-empty slice
  rejects a null pointer. Everything here needs `unsafe` — not because the
  accesses are unchecked, but because the compiler cannot prove the backing
  allocation is still alive.

Use it when:
  - You want to pass "part of this buffer" to a function without copying it.
    `sum_view` below takes any window over any i32 memory.
  - You are talking to C or to mapped/raw memory and need a length carried
    alongside the pointer.
  - You want to split a buffer into pieces that all write into the same
    storage — `middle.set(1, 99)` below shows up in `all`.

Don't use it when:
  - You want something that owns its memory and grows -> use List<T>.
  - The data must outlive the allocation. A Slice is a view; if you `free` the
    backing pointer, every slice over it is dangling. Keep the owner alive.

Element types are limited to the raw-memory set (inline scalars, RawPtr, fixed
arrays, SIMD, C-layout structs and unions) — no ARC values.
*/

import std.io

fn sum_view(view: Slice<i32>) -> i32 {
    var total: i32 = 0
    unsafe {
        for value: i32 in view {
            total += value
        }
    }
    return total
}

fn main() {
    unsafe {
        let storage: RawPtr<i32> = RawPtr.alloc(6)
        let all: Slice<i32> = Slice.from_raw(storage, 6)
        var index: int = 0
        for index < all.len() {
            all.set(index, ((index + 1) * 10) as i32)
            index += 1
        }
        let middle: Slice<i32> = all.subslice(1, 5)
        middle.set(1, 99)
        io.println("slice {middle.len()} {middle[0]} {middle.get(2)} {sum_view(middle)}")
        io.println("slice ptr {middle.as_ptr() == storage.offset(1)} tail {all[5]}")
        storage.free()
    }
}

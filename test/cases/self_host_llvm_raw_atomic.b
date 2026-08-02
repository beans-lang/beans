import std.io

fn main() {
    unsafe {
        let flag: RawPtr<bool> = RawPtr.alloc(1)
        flag.write_volatile(true)

        let counter: RawPtr<i32> = RawPtr.alloc(1)
        counter.atomic_store(10)
        let old: i32 = counter.atomic_fetch_add(5)
        let swapped: bool =
            counter.atomic_compare_exchange(15, 21)

        io.println("raw {flag.read_volatile()} {old} {swapped} {counter.atomic_load()}")

        counter.free()
        flag.free()
    }
}

import std.io

fn main() {
    unsafe {
        let memory: RawPtr<i32> =
            RawPtr.alloc_aligned(8, 16)
        let values: Slice<i32> =
            Slice.from_raw(memory, 4)
        values.set(0, 1)
        values.set(1, 2)
        values.set(2, 3)
        values.set(3, 4)

        let middle: Slice<i32> =
            values.subslice(1, 4)
        var total: i32 = 0
        for value: i32 in middle {
            total += value
        }
        io.println(
            "slice {values.len()} {values.get(2)} {total} {values.as_ptr() == memory}")

        let lanes: Simd4i32 =
            Simd4i32.load(memory)
        let mask: Simd4i32 =
            lanes.gt(Simd4i32.splat(2))
        let picked: Simd4i32 =
            mask.select(
                lanes.add(Simd4i32.splat(10)),
                lanes)
        picked.store(memory)
        io.println(
            "simd {picked.lane_count()} {picked.lane(0)} {picked.lane(3)} {picked.sum()} {mask.any_true()} {mask.all_true()}")

        memory.free()
    }
}

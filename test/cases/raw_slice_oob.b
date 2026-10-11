fn main() {
    unsafe {
        let storage: RawPtr<i32> = RawPtr.alloc(2)
        let view: Slice<i32> = Slice.from_raw(storage, 2)
        view[2]
        storage.free()
    }
}

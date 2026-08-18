fn main() {
    let pointer: RawPtr<u8> = RawPtr.null()
    unsafe {
        let value: Bytes = Bytes.from_raw(pointer, -1)
    }
}

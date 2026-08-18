fn bad(pointer: RawPtr<u8>, bytes: Bytes) {
    let copied: Bytes = Bytes.from_raw(pointer, 1)
    let borrowed: RawPtr<u8> = bytes.as_ptr()
}

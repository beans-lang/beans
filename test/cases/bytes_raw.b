import std.io

fn main() {
    var null_pointer: RawPtr<u8> = RawPtr.null()
    io.println(null_pointer.is_null())

    var source: RawPtr<u8> = RawPtr.null()
    unsafe {
        source = RawPtr.alloc(4)
        source.write(1 as u8)
        source.offset(1).write(2 as u8)
        source.offset(2).write(3 as u8)
        source.offset(3).write(4 as u8)

        let copied: Bytes = Bytes.from_raw(source, 4)
        source.write(99 as u8)
        io.println("{copied.get(0)} {copied.get(3)}")

        let borrowed: RawPtr<u8> = copied.as_ptr()
        borrowed.offset(1).write(9 as u8)
        io.println("{copied.get(0)} {copied.get(1)} {copied.get(2)} {copied.get(3)}")

        let empty: Bytes = Bytes.from_raw(null_pointer, 0)
        io.println("{empty.len()} {empty.as_ptr().is_null()}")
        source.free()
    }
}

import std.io

fn main() {
    unsafe {
        var p: RawPtr<u64> = RawPtr.alloc(4)
        p.write(11)
        p.offset(1).write(22)
        p.offset(2).write(33)
        io.println(p.read())
        io.println(p.offset(1).read())
        io.println(p.offset(2).read())
        io.println(p.is_null())
        let n: RawPtr<u8> = RawPtr.null()
        io.println(n.is_null())
        let q: RawPtr<u64> = RawPtr.from_address(p.address())
        io.println(q.read())
        var bytes: RawPtr<u8> = RawPtr.alloc(3)
        bytes.fill_zero(3)
        bytes.write(65)
        io.println(bytes.read())
        io.println(bytes.offset(1).read())
        bytes.free()
        p.free()
    }
}

import std.io
import std.c

extern "C" opaque struct Handle

extern "C" fn local_abs(value: i32) -> i32 as "abs"

pub extern "C" fn local_add(a: i32, b: i32) -> i32 as "beans_self_add" {
    return a + b
}

fn main() {
    c.set_errno(37)
    unsafe {
        io.println(local_abs(-7))
    }
    io.println(local_add(20, 22))
    io.println(c.errno())
}

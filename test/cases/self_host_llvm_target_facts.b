import std.io
import std.target

fn main() {
    io.println("{target.triple()} {target.arch()} {target.os()} {target.env()}")
    io.println("{target.object_format()} {target.endian()}")
    io.println("{target.pointer_bits()} {target.pointer_size()} {target.stack_align()} {target.max_simd_bits()}")
}

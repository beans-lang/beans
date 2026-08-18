// The selected build target, reported by the compiler rather than guessed at
// runtime. `beansc run` and a host `beansc build` both describe the host;
// `beansc build --target <triple>` describes that target instead, which is why
// these are compile-time facts and not a runtime lookup.

import std.io
import std.target

fn describe() -> string {
    return "{target.arch()}-{target.os()}-{target.env()}"
}

fn main() {
    io.println("triple:        {target.triple()}")
    io.println("arch:          {target.arch()}")
    io.println("os:            {target.os()}")
    io.println("env:           {target.env()}")
    io.println("object format: {target.object_format()}")
    io.println("endian:        {target.endian()}")
    io.println("pointer bits:  {target.pointer_bits()}")
    io.println("pointer size:  {target.pointer_size()}")
    io.println("stack align:   {target.stack_align()}")
    io.println("max simd bits: {target.max_simd_bits()}")

    // The facts are ordinary values, so they compose like any other.
    io.println("shape:         {describe()}")

    let pointer_bytes: int = target.pointer_size()
    if pointer_bytes * 8 == target.pointer_bits() {
        io.println("pointer size and bits agree")
    } else {
        io.println("pointer size and bits disagree")
    }
}

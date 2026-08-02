// A feature from another architecture is a compile error, not a permanent false.
import std.cpu

fn main() {
    let v: bool = cpu.has(CpuFeature.avx512f)
}

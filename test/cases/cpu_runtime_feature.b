// The feature selects which detection bit is read, so it cannot be a variable.
import std.cpu

fn main() {
    let picked: CpuFeature = CpuFeature.aes
    let v: bool = cpu.has(picked)
}

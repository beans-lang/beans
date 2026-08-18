// Guarding on one feature does not license another.
import std.cpu

feature "aes" fn needs_aes() -> int { return 1 }

fn main() {
    if cpu.has(CpuFeature.crc) {
        let v: int = needs_aes()
    }
}

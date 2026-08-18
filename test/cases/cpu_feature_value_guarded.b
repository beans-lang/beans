// Once the runtime guard proves the machine has the feature, the stored value is safe.
import std.cpu

feature "aes" fn needs_aes() -> int { return 1 }

fn main() {
    if cpu.has(CpuFeature.aes) {
        let guarded: fn() -> int = needs_aes
        let value: int = guarded()
    }
}

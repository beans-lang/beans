// cpu.has through the self-host LLVM emitter. Feature names are
// per-architecture (neon exists only on arm64), so the suite emits
// this case with an explicit arm64 target and checks the IR shape
// rather than running it — an x86 host would refuse the token at
// check time, which is the target model doing its job.
import std.io
import std.cpu

fn main() {
    if cpu.has(CpuFeature.neon) {
        io.println("neon present")
    } else {
        io.println("neon absent")
    }
}

// CPU feature detection and safe dispatch.
//
// A program is often compiled once and run on machines with different
// instructions. The pattern is: write a fast path that needs a feature, write a
// path that needs nothing, and pick between them at run time.
//
// Two pieces make that safe:
//
//   * `cpu.has(CpuFeature.aes)` asks the machine that is *running*, not the one the
//     program was compiled for.
//   * `feature "aes" fn` marks a body as allowed to use that feature's
//     instructions. Only a marked function carries the permission, so the compiler
//     cannot hoist a feature-requiring instruction out of it into a caller that
//     never checked.
//
// The compiler then requires the guard: calling a marked function anywhere the
// feature is not known present is an error, not a crash on the wrong machine.
//
// `aes` is used here because both x86-64 and arm64 have it in their feature sets,
// so this one file compiles for either.

import std.io
import std.cpu

// The fast path. Marked, so it may use the feature's instructions.
feature "aes" fn mix_fast(seed: int, rounds: int) -> int {
    var acc: int = seed
    var i: int = 0
    for i < rounds {
        acc = (acc * 31 + i) % 1000003
        i += 1
    }
    return acc
}

// The path that needs nothing. Same answer, always available.
fn mix_generic(seed: int, rounds: int) -> int {
    var acc: int = seed
    var i: int = 0
    for i < rounds {
        acc = (acc * 31 + i) % 1000003
        i += 1
    }
    return acc
}

// The dispatch. This is the only place the feature is named.
fn mix(seed: int, rounds: int) -> int {
    if cpu.has(CpuFeature.aes) {
        return mix_fast(seed, rounds)
    }
    return mix_generic(seed, rounds)
}

fn main() {
    // The point of a dispatch is that the answer does not depend on which path
    // ran. Printing the answer, not the feature, is what keeps this output the same
    // on every machine — and it is also the property worth asserting.
    let dispatched: int = mix(7, 1000)
    let generic: int = mix_generic(7, 1000)
    io.println("result {dispatched}")
    io.println("paths agree {dispatched == generic}")

    // A guard can cover several features at once, and nests.
    if cpu.has(CpuFeature.aes) {
        if cpu.has(CpuFeature.aes) {
            io.println("nested guard {mix_fast(1, 10)}")
        }
    }

    // Asking about a feature is always allowed, and always answers about this
    // machine. Whether it is present is a property of the CPU, so the example
    // prints something derived rather than the answer itself.
    let present: bool = cpu.has(CpuFeature.aes)
    io.println("answer is a bool {present == true || present == false}")

    // BEANS_CPU_FEATURES can hide a feature to force the generic path. It can only
    // ever remove: a test may pretend hardware is missing, never that it is there.
    io.println("done")
}

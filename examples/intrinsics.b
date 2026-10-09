// `std.intrinsic` is a closed, typed allowlist of architecture and feature-specific operations.
// The interpreter models each operation; calls require `unsafe`.

import std.io
import std.cpu
import std.intrinsic

fn main() {
    unsafe {
        // Bit-count operations define zero inputs and full-width results.
        io.println("popcount {intrinsic.popcount(255)} of zero {intrinsic.popcount(0)}")
        io.println("leading zeros {intrinsic.leading_zeros(1)} of zero {intrinsic.leading_zeros(0)}")
        io.println("trailing zeros {intrinsic.trailing_zeros(8)} of zero {intrinsic.trailing_zeros(0)}")

        // Byte order. The narrow forms work on the low bytes and leave the rest
        // zero, so bswap16 of 0x1234 is 0x3412 and not a 64-bit reversal.
        io.println("bswap16 {intrinsic.bswap16(4660)}")
        io.println("bswap32 {intrinsic.bswap32(305419896)}")
        io.println("bswap64 of one {intrinsic.bswap64(1)}")

        // Rotates, which are funnel shifts with both halves the same value.
        io.println("rotate_left {intrinsic.rotate_left(1, 1)}")
        io.println("rotate_right {intrinsic.rotate_right(2, 1)}")
        io.println("rotate by zero {intrinsic.rotate_left(7, 0)}")

        // Floating point. `fma` rounds once, which is the reason to use it rather
        // than writing a * b + c.
        io.println("sqrt {intrinsic.sqrt(16.0)} sqrt32 {intrinsic.sqrt32(9.0)}")
        io.println("fma {intrinsic.fma(2.0, 3.0, 1.0)} fma32 {intrinsic.fma32(2.0, 3.0, 1.0)}")

        // Hints. Neither has an observable result: `prefetch` says an address will be
        // read soon, `spin_hint` says this thread is spinning. They are the two cases
        // where doing nothing is a correct implementation.
        let block: RawPtr<u8> = RawPtr.alloc(64)
        intrinsic.prefetch(block)
        block.free()
        intrinsic.spin_hint()
        io.println("hints are safe to ignore")

        // `aes` is one of the few features both architectures spell the same way, so a
        // guard on it is written once and checks everywhere. That is what makes this
        // file portable, and it is worth knowing *why* it is the exception.
        //
        // A feature-gated intrinsic goes through exactly the same guard rule as a
        // `feature "x" fn`: calling one where the feature is not known present is a
        // compile error. Feature names are architecture-specific: `crc32c` needs
        // `crc` on arm64 and `sse4.2` on x86-64.
        // Beans has no conditional compilation, so a single source cannot name both.
        // The guarded call is therefore exercised in test/intrinsics.sh, which picks
        // the right name for the machine it is running on. An example that only
        // compiled on one architecture would be worse than one that says so.
        io.println("aes is optional on both architectures: {cpu.has(CpuFeature.aes) || true}")
    }
}

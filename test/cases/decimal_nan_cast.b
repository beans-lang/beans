// Casting NaN to decimal panics as decimal overflow, at the cast's
// own position, identically in every implementation — the audit
// found the interpreter turning "nan" into coefficient 6752 and the
// self-host tree interpreter panicking with its own source location.
import std.io
fn main() {
    let zero: float = 0.0
    let bad: float = 0.0 / zero
    io.println("before")
    let boom: decimal = bad as decimal
    io.println("{boom}")
}

// The parts of std.math with exact answers: the ordering helpers, the
// Euclidean remainder that `%` does not give, hypot's scaling, and the f32
// twins. Every value here is one a reader can check by eye, which is the point
// — the transcendentals cannot be checked that way and are gated against libm
// patterns in test/math.sh instead.
package main

import std.io
import std.math

fn main() {
    io.println("clamp {math.clamp(7, 1, 5)} {math.clamp(-2, 1, 5)} {math.clamp(3, 1, 5)}")
    io.println("gcd {math.gcd(12, 18)} {math.gcd(-12, 18)} {math.gcd(0, 0)}")

    io.println("fmax {math.fmax(2.5, 1.5)} {math.fmax(-2.5, -1.5)}")
    io.println("fmin {math.fmin(2.5, 1.5)} {math.fmin(-2.5, -1.5)}")
    io.println("fclamp {math.fclamp(7.5, 1.0, 5.0)} {math.fclamp(-1.0, 1.0, 5.0)}")

    // `%` keeps the sign of the dividend; rem_euclid never does
    io.println("rem {-7.0 % 3.0} euclid {math.rem_euclid(-7.0, 3.0)}")
    io.println("euclid0 {math.rem_euclid(5.0, 0.0)}")

    io.println("sqrt {math.sqrt(9.0)} {math.sqrt(0.0)}")
    io.println("hypot {math.hypot(3.0, 4.0)} {math.hypot(0.0, 0.0)}")

    // the scaling is what keeps the squares from overflowing
    let huge: float = 1.0e200
    io.println("hypot big {math.hypot(3.0 * huge, 4.0 * huge) / huge}")

    io.println("finite {math.is_finite(1.0)} {math.is_finite(math.infinity())}")
    io.println("finite32 {math.is_finite32(1.0)} {math.is_finite32(math.infinity32())}")

    // the f32 twins answer the same shapes
    io.println("f32 {math.fmax32(2.5, 1.5)} {math.fmin32(2.5, 1.5)} {math.fclamp32(7.5, 1.0, 5.0)}")
    io.println("f32 rem {math.rem_euclid32(-7.0, 3.0)} sqrt {math.sqrt32(9.0)} hypot {math.hypot32(3.0, 4.0)}")

    // the transcendentals at points with exact answers
    io.println("exp0 {math.exp(0.0)} sin0 {math.sin(0.0)} cos0 {math.cos(0.0)}")
    io.println("exp32 {math.exp32(0.0)} sin32 {math.sin32(0.0)} cos32 {math.cos32(0.0)}")

    // past the limit the reduction cannot be honest, so the answer is not one
    io.println("past {math.sin(1.0e16).is_nan()} {math.cos(1.0e16).is_nan()}")
    io.println("limit {math.angle_limit()}")
}

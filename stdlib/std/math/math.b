// High-level numeric helpers written in Beans, not C++.

package math

import std.intrinsic

/// Clamp `value` into the inclusive range `[low, high]`.
///
/// When to use: keeping an index or measurement within known bounds without
/// writing the two comparisons by hand. Returns `low` if `value < low`, `high`
/// if `value > high`, otherwise `value` unchanged.
pub fn clamp(value: int, low: int, high: int) -> int {
    if value < low {
        return low
    }
    if value > high {
        return high
    }
    return value
}

/// Greatest common divisor of `a` and `b`, using the Euclidean algorithm.
///
/// When to use: reducing fractions or finding a common step size. Operates on
/// absolute values, so signs of the inputs do not affect the result; `gcd(0, 0)`
/// is `0`.
pub fn gcd(a: int, b: int) -> int {
    var x: int = a.abs()
    var y: int = b.abs()
    for y != 0 {
        let next: int = x % y
        x = y
        y = next
    }
    return x
}

// ---- floating-point helpers ------------------------------------------------
//
// `clamp` and `gcd` above are integer helpers. Everything below works in
// `float` (f64) with an `f32` twin named with a `32` suffix, matching the
// convention `std.intrinsic` already sets with `sqrt`/`sqrt32` and `fma`/
// `fma32`. Names that would collide with the integer helpers carry C's `f`
// prefix, so `clamp` stays integer and `fclamp` is its float twin.
//
// These are written in Beans rather than bound to the platform's libm on
// purpose: a freestanding or `wasm32-unknown-unknown` build has no libm, and a
// std module that silently does not exist on some targets is worse than one
// that works everywhere.

/// Positive infinity.
pub fn infinity() -> float {
    let big: float = 1.0e300
    return big * big
}

/// Positive infinity as an `f32`.
pub fn infinity32() -> f32 {
    let big: f32 = 1.0e30
    return big * big
}

/// The quiet NaN these answer with when they refuse.
fn not_a_number() -> float {
    let endless: float = infinity()
    return endless - endless
}

/// True when `value` is neither infinite nor NaN.
///
/// `v - v` is zero for every finite value and NaN for an infinity or a NaN,
/// and NaN compares false against everything, so one subtraction answers both.
pub fn is_finite(value: float) -> bool {
    return (value - value) == 0.0
}

/// True when `value` is neither infinite nor NaN.
pub fn is_finite32(value: f32) -> bool {
    return (value - value) == 0.0
}

/// The larger of two floats. NaN is not ordered, so a NaN argument answers
/// whichever side the comparison falls through to — test with `is_nan` first
/// when that matters.
pub fn fmax(left: float, right: float) -> float {
    if left > right {
        return left
    }
    return right
}

/// The larger of two `f32` values.
pub fn fmax32(left: f32, right: f32) -> f32 {
    if left > right {
        return left
    }
    return right
}

/// The smaller of two floats.
pub fn fmin(left: float, right: float) -> float {
    if left < right {
        return left
    }
    return right
}

/// The smaller of two `f32` values.
pub fn fmin32(left: f32, right: f32) -> f32 {
    if left < right {
        return left
    }
    return right
}

/// `value` held inside the inclusive range `[low, high]`.
pub fn fclamp(value: float, low: float, high: float) -> float {
    if value < low {
        return low
    }
    if value > high {
        return high
    }
    return value
}

/// `value` held inside the inclusive range `[low, high]`.
pub fn fclamp32(value: f32, low: f32, high: f32) -> f32 {
    if value < low {
        return low
    }
    if value > high {
        return high
    }
    return value
}

/// The Euclidean remainder, never negative.
///
/// `%` is the truncated remainder and keeps the sign of the dividend. Wrapping
/// an angle or a hue needs the floored one, which is what this gives.
pub fn rem_euclid(value: float, divisor: float) -> float {
    if divisor == 0.0 {
        return 0.0
    }
    let rest: float = value % divisor
    if rest < 0.0 {
        return rest + divisor.abs()
    }
    return rest
}

/// The Euclidean remainder of two `f32` values, never negative.
pub fn rem_euclid32(value: f32, divisor: f32) -> f32 {
    if divisor == 0.0 {
        return 0.0
    }
    let rest: f32 = value % divisor
    if rest < 0.0 {
        return rest + divisor.abs()
    }
    return rest
}

/// The square root of a non-negative float.
///
/// This is the hardware instruction through `std.intrinsic`, so it is
/// correctly rounded. The wrapper exists so callers need no `unsafe` block.
pub fn sqrt(value: float) -> float {
    unsafe {
        return intrinsic.sqrt(value)
    }
}

/// The square root of a non-negative `f32`.
pub fn sqrt32(value: f32) -> f32 {
    unsafe {
        return intrinsic.sqrt32(value)
    }
}

/// The length of the vector `(x, y)`, without overflowing on the squares.
pub fn hypot(x: float, y: float) -> float {
    let large: float = fmax(x.abs(), y.abs())
    if large == 0.0 {
        return 0.0
    }
    if !is_finite(large) {
        return large
    }
    let small: float = fmin(x.abs(), y.abs())
    let ratio: float = small / large
    return large * sqrt(1.0 + ratio * ratio)
}

/// The length of the vector `(x, y)` in `f32`.
pub fn hypot32(x: f32, y: f32) -> f32 {
    let large: f32 = fmax32(x.abs(), y.abs())
    if large == 0.0 {
        return 0.0
    }
    if !is_finite32(large) {
        return large
    }
    let small: f32 = fmin32(x.abs(), y.abs())
    let ratio: f32 = small / large
    return large * sqrt32(1.0 + ratio * ratio)
}

// ---- the transcendentals ---------------------------------------------------
//
// exp, sin and cos follow fdlibm's shape: reduce the argument against a
// multi-part constant, evaluate a minimax polynomial on the small remainder,
// and scale back. Three details carry the accuracy, and each was measured
// rather than assumed:
//
//   * every leading constant piece has its low 32 bits clear, so the product
//     `n * piece` is EXACT and the big subtraction below it cannot cancel away
//     bits that were never there. Without this, exp sits at ~48 ulp.
//   * the pi/2 pieces are SUCCESSIVE residuals, not re-splits of each other.
//     Subtracting a re-split removes the same quantity twice; that mistake
//     costs sin ~36000 ulp at arguments in the thousands and is invisible at
//     the small angles an animation uses.
//   * `1 - z/2` in the cosine kernel is compensated. When z approaches 1 the
//     subtraction cancels, and adding the cancelled part back is worth ~25 ulp.
//
// Measured against the platform's libm by comparing raw 64-bit patterns rather
// than printed digits, over 22,924 points spanning exp's whole finite range and
// angles out to |x| ~ 8.8e5:
//
//     exp   1 ulp, and exact where the result is subnormal
//     sin   2 ulp
//     cos   2 ulp
//
// and 0 ulp — bit-identical to libm — at the multiples of pi/2, where the
// answer is made almost entirely of the reduction residual and a shorter
// constant would have built it from bits that were rounded away.
//
// test/math.sh reproduces the comparison against committed vectors, and
// tools/gen_math_vectors.py records how those were derived. That derivation is
// deliberately kept beside them: at f32 a vector is a constant a reader can
// check by eye, and at f64 nobody checks seventeen digits, so what the numbers
// came FROM becomes the thing under test.

/// Two raised to a whole power, exactly.
///
/// Powers of two are exact in binary floating point, so squaring accumulates
/// no error. The exponent is halved so that neither factor overflows or
/// underflows on its own.
fn pow2_half(k: int) -> float {
    var base: float = 2.0
    var n: int = k
    if n < 0 {
        base = 0.5
        n = -n
    }
    var acc: float = 1.0
    for n > 0 {
        if (n & 1) == 1 {
            acc = acc * base
        }
        base = base * base
        n = n >> 1
    }
    return acc
}

fn pow2(k: int) -> float {
    if k > 1023 {
        return infinity()
    }
    if k < -1074 {
        return 0.0
    }
    let half: int = k / 2
    return pow2_half(half) * pow2_half(k - half)
}

/// `e` raised to `power`.
///
/// `power = k*ln2 + r` with `|r| <= ln2/2`, a degree-5 minimax polynomial for
/// the correction on `r`, then an exact scale by `2^k`. `ln2` is carried as a
/// head with clear low bits plus a tail, so `k * head` is exact.
pub fn exp(power: float) -> float {
    if power.is_nan() {
        return power
    }
    if power > 709.782712893384 {
        return infinity()
    }
    if power < -745.1332191019411 {
        return 0.0
    }
    if power.abs() < 1.0e-300 {
        return 1.0 + power
    }
    let scaled: float = power * 1.4426950408889634
    var k: int = 0
    if scaled >= 0.0 {
        k = (scaled + 0.5).floor() as int
    } else {
        k = (scaled - 0.5).ceil() as int
    }
    let whole: float = k as float
    let head: float = power - whole * 0.6931471803691238
    let tail: float = whole * 1.9082149292705877e-10
    let rest: float = head - tail
    let square: float = rest * rest
    let correction: float =
        rest - square * (0.16666666666666602 +
            square * (-0.0027777777777015593 +
            square * (0.00006613756321437934 +
            square * (-0.0000016533902205465252 +
            square * 0.00000004138136797057238))))
    let value: float =
        1.0 - ((tail - (rest * correction) / (2.0 - correction)) - head)
    // Both ends need the scale split: the last binade overflows to infinity
    // before `value` can bring it down, and a subnormal answer flushes to
    // zero before `value` can lift it up.
    if k >= 1024 {
        return (value * pow2(k - 1)) * 2.0
    }
    if k <= -1021 {
        return (value * pow2(k + 54)) * pow2(-54)
    }
    return value * pow2(k)
}

/// `e` raised to `power`, in `f32`.
///
/// Evaluated in f64 and narrowed once, which is more accurate than an f32
/// kernel would be. The bounds are where an f32 result is an infinity or a
/// zero anyway.
pub fn exp32(power: f32) -> f32 {
    if power.is_nan() {
        return power
    }
    if power > 88.8 {
        return infinity32()
    }
    if power < -104.0 {
        return 0.0
    }
    return exp(power as float) as f32
}

/// The part of `left + right` that did not fit in the sum — Knuth's two-sum.
///
/// Exact for any two floats, with no fast-math anywhere in the emitted IR to
/// optimize it away: the compiler emits plain `fadd`/`fsub` with no reassociation
/// flags, so the cancellation this depends on really happens.
fn sum_error(left: float, right: float, total: float) -> float {
    let split: float = total - left
    return (left - (total - split)) + (right - split)
}

/// The sine of `head + tail` on `|head| <= pi/4`, where the series converges
/// fast. `tail` is the part of the reduced argument that did not fit in
/// `head`; it is what keeps the answer accurate where sine is near zero and
/// the result is made almost entirely of that remainder.
fn kernel_sin(head: float, tail: float) -> float {
    let square: float = head * head
    let cube: float = square * head
    let series: float =
        0.00833333333332248946124 +
        square * (-0.000198412698298579493134 +
        square * (0.00000275573137070700676789 +
        square * (-0.0000000250507602534068634195 +
        square * 0.000000000158969099521155010221)))
    if tail == 0.0 {
        return head +
            cube * (-0.166666666666666324348 + square * series)
    }
    return head -
        ((square * (0.5 * tail - cube * series) - tail) -
         cube * -0.166666666666666324348)
}

/// The cosine of `head + tail` on `|head| <= pi/4`.
fn kernel_cos(head: float, tail: float) -> float {
    let square: float = head * head
    let poly: float =
        square * (0.0416666666666666019037 +
        square * (-0.00138888888888741095749 +
        square * (0.0000248015872894767294178 +
        square * (-0.000000275573143513906633035 +
        square * (0.00000000208757232129817482790 +
        square * -0.0000000000113596475577881948265)))))
    let correction: float = square * poly - head * tail
    // `1 - z/2` cancels when z approaches 1, so the part that cancelled is
    // added back. Below 0.3 there is nothing to compensate; above it the
    // subtraction is staged through a constant that is exact in binary so the
    // intermediate keeps its bits.
    if head.abs() < 0.3 {
        return 1.0 - (0.5 * square - correction)
    }
    var stage: float = 0.28125
    if head.abs() <= 0.78125 {
        stage = head * 0.25
    }
    let half: float = 0.5 * square - stage
    return (1.0 - stage) - (half - correction)
}

/// How far `radians` sits from the nearest multiple of pi/2, and which
/// quadrant that multiple lands in.
class QuarterTurn {
    /// The multiple of pi/2, modulo 4.
    quadrant: int
    /// The remainder, in `[-pi/4, pi/4]`.
    rest: float
    /// The part of the remainder that did not fit in `rest`. Near a multiple
    /// of pi/2 the answer is made almost entirely of this, which is why the
    /// reduction carries it instead of rounding it away.
    tail: float

    fn init(quadrant: int, rest: float, tail: float) {
        self.quadrant = quadrant
        self.rest = rest
        self.tail = tail
    }
}

/// pi/2 as seven successive pieces, each with its low 32 bits clear, so every
/// product `n * piece` is exact and only the subtractions round — and two-sum
/// keeps what they dropped. Seven pieces carry pi/2 to about 260 bits. Four
/// would be enough for a result of ordinary size; the extra three are for the
/// answers near a multiple of pi/2, which are made almost entirely of the
/// residual and would otherwise be built from bits that were rounded away.
fn reduce_quarter(radians: float) -> QuarterTurn {
    let scaled: float = radians * 0.6366197723675814
    var n: int = 0
    if scaled >= 0.0 {
        n = (scaled + 0.5).floor() as int
    } else {
        n = (scaled - 0.5).ceil() as int
    }
    let whole: float = n as float
    // Each product below is exact — the piece has 21 significant bits and `n`
    // fits in 20 — so only the subtractions round, and two-sum keeps what they
    // dropped. Without the tail, sin near a multiple of pi is made of bits
    // that were thrown away, and the answer looks right while being wrong by
    // most of itself.
    var rest: float = radians - whole * 1.570796012878418
    var tail: float = 0.0
    var product: float = whole * 3.139164164167596e-07
    var total: float = rest - product
    tail = tail + sum_error(rest, -product, total)
    rest = total
    product = whole * 6.223369259164557e-14
    total = rest - product
    tail = tail + sum_error(rest, -product, total)
    rest = total
    product = whole * 2.9127304114676625e-20
    total = rest - product
    tail = tail + sum_error(rest, -product, total)
    rest = total
    product = whole * 1.644624610775752e-26
    total = rest - product
    tail = tail + sum_error(rest, -product, total)
    rest = total
    product = whole * 1.0828565797698601e-32
    total = rest - product
    tail = tail + sum_error(rest, -product, total)
    rest = total
    product = whole * 9.415205271428978e-40
    total = rest - product
    tail = tail + sum_error(rest, -product, total)
    rest = total
    // renormalize so `rest` carries the leading bits and `tail` the rest
    total = rest + tail
    tail = tail - (total - rest)
    rest = total
    var quadrant: int = n % 4
    if quadrant < 0 {
        quadrant = quadrant + 4
    }
    return new QuarterTurn(quadrant, rest, tail)
}

/// The largest `|radians|` these still reduce accurately. Past it the argument
/// carries fewer bits than a full turn needs, so the answer would be a
/// confident guess; `sin` and `cos` answer NaN there instead.
pub fn angle_limit() -> float {
    return 1.0e15
}

/// The sine of an angle in radians.
///
/// Answers NaN when `|radians|` exceeds `angle_limit()`: past that an f64
/// carries fewer bits than a full turn needs, so any answer would be invented.
pub fn sin(radians: float) -> float {
    if radians.is_nan() {
        return radians
    }
    if radians.abs() > 1.0e15 {
        return not_a_number()
    }
    let cut: QuarterTurn = reduce_quarter(radians)
    if cut.quadrant == 0 {
        return kernel_sin(cut.rest, cut.tail)
    }
    if cut.quadrant == 1 {
        return kernel_cos(cut.rest, cut.tail)
    }
    if cut.quadrant == 2 {
        return -kernel_sin(cut.rest, cut.tail)
    }
    return -kernel_cos(cut.rest, cut.tail)
}

/// The cosine of an angle in radians. NaN past `angle_limit()`, like `sin`.
pub fn cos(radians: float) -> float {
    if radians.is_nan() {
        return radians
    }
    if radians.abs() > 1.0e15 {
        return not_a_number()
    }
    let cut: QuarterTurn = reduce_quarter(radians)
    if cut.quadrant == 0 {
        return kernel_cos(cut.rest, cut.tail)
    }
    if cut.quadrant == 1 {
        return -kernel_sin(cut.rest, cut.tail)
    }
    if cut.quadrant == 2 {
        return -kernel_cos(cut.rest, cut.tail)
    }
    return kernel_sin(cut.rest, cut.tail)
}

/// The sine of an angle in radians, in `f32`.
pub fn sin32(radians: f32) -> f32 {
    return sin(radians as float) as f32
}

/// The cosine of an angle in radians, in `f32`.
pub fn cos32(radians: f32) -> f32 {
    return cos(radians as float) as f32
}

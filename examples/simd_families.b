// SIMD vector families.
//
// A vector type's name is its shape: `Simd` + lane count + element. So
// `Simd4i32` is four 32-bit signed integers, `Simd16u8` is sixteen bytes, and
// `Simd2f64` is two doubles. Every family gets the same operations, because the
// name is parsed into (lanes, element) once and everything downstream is driven by
// those two numbers.
//
// The total width has to be a register the machine actually has. 128-bit works
// everywhere; 256-bit needs the feature that provides it, so `Simd8i32` compiles
// for x86-64 with `--features +avx2` and is refused without it, by name.
//
// Vectors are raw hardware, so the operations need `unsafe`.

import std.io

fn main() {
    unsafe {
        let counts: Simd4i32 = Simd4i32.of(1, 2, 3, 4)
        let ten: Simd4i32 = Simd4i32.splat(10)

        io.println("shape {counts.lane_count()} lanes")
        io.println("lanes {counts.lane(0)} {counts.lane(1)} {counts.lane(2)} {counts.lane(3)}")

        // Lane-wise arithmetic. One instruction, four results.
        io.println("add {counts.add(ten).lane(3)}")
        io.println("sub {ten.sub(counts).lane(0)}")
        io.println("mul {counts.mul(ten).lane(2)}")
        io.println("div {ten.div(counts).lane(1)}")
        io.println("min {counts.min(ten).lane(3)} max {counts.max(ten).lane(0)}")

        // A copy with one lane replaced. Vectors are values, so `counts` is
        // untouched.
        let patched: Simd4i32 = counts.with_lane(1, 99)
        io.println("with_lane {patched.lane(1)} original {counts.lane(1)}")

        // Reductions fold every lane into one scalar.
        io.println("sum {counts.sum()} product {counts.product()}")

        // A comparison gives a mask: every lane is all-ones or all-zeros. That is
        // the shape `select` takes, so a comparison feeds straight into a choice
        // with no branch anywhere.
        let big: Simd4i32 = counts.gt(Simd4i32.splat(2))
        io.println("mask any {big.any_true()} all {big.all_true()}")
        let picked: Simd4i32 = big.select(ten, counts)
        io.println("select {picked.lane(0)} {picked.lane(1)} {picked.lane(2)} {picked.lane(3)}")
        io.println("none {counts.gt(Simd4i32.splat(100)).any_true()}")
        io.println("every {counts.ge(Simd4i32.splat(1)).all_true()}")

        // Bitwise and shifts, on integer families only — there is no meaningful
        // bitwise-and of two floats, so those methods are not offered on f32/f64.
        io.println("or {counts.bit_or(ten).lane(0)}")
        io.println("and {counts.bit_and(ten).lane(1)}")
        io.println("xor {counts.bit_xor(ten).lane(2)}")
        io.println("not {counts.bit_not().lane(0)}")
        io.println("shl {counts.shl(2).lane(1)} shr {ten.shr(1).lane(0)}")

        // Sixteen bytes at a time. Unsigned lanes wrap, and the comparison is
        // unsigned too — 200 is above 100 here, which it would not be if the lanes
        // were read as signed.
        let bytes: Simd16u8 = Simd16u8.splat(200)
        io.println("u8 lanes {bytes.lane_count()} lane {bytes.lane(0)}")
        io.println("u8 wrap {bytes.add(Simd16u8.splat(100)).lane(0)}")
        io.println("u8 unsigned compare {bytes.gt(Simd16u8.splat(100)).all_true()}")
        // An unsigned right shift brings in zeros; the signed one below brings in
        // the sign bit. Same method name, different instruction, chosen by the type.
        io.println("u8 shr {bytes.shr(1).lane(0)}")

        // Signed narrow lanes: the shift carries the sign bit down.
        let negatives: Simd8i16 = Simd8i16.splat(-8)
        io.println("i16 {negatives.lane(0)} shr {negatives.shr(2).lane(0)} sum {negatives.sum()}")

        // Doubles.
        let pair: Simd2f64 = Simd2f64.of(1.5, 2.5)
        io.println("f64 sum {pair.sum()} scaled {pair.mul(Simd2f64.splat(2.0)).lane(1)}")

        // Floats compare too; the mask is the same shape as the vector.
        let halves: Simd4f32 = Simd4f32.of(0.5, 1.5, 2.5, 3.5)
        io.println("f32 above {halves.gt(Simd4f32.splat(2.0)).any_true()}")
        io.println("f32 min {halves.min(Simd4f32.splat(2.0)).lane(3)}")

        // Whole-vector equality is a value comparison, lane by lane.
        io.println("equal {counts == Simd4i32.of(1, 2, 3, 4)} {counts == ten}")

        // Aligned load and store. `load`/`store` require the vector's own
        // alignment and panic otherwise; the `_unaligned` forms take any address.
        // Eight lanes of room, so the unaligned write below stays inside it.
        let block: RawPtr<i32> = RawPtr.alloc_aligned(8, 16)
        counts.store(block)
        io.println("roundtrip {Simd4i32.load(block).lane(2)}")
        let shifted: RawPtr<u8> = RawPtr.from_address(block.address() + 1)
        let loose: RawPtr<i32> = RawPtr.from_address(shifted.address())
        counts.store_unaligned(loose)
        io.println("unaligned roundtrip {Simd4i32.load_unaligned(loose).lane(1)}")
        block.free()
    }
}

import std.io

fn main() {
    let two_half: decimal = 2.5
    let three_half: decimal = 3.5
    let one_low: decimal = 1.225
    let one_high: decimal = 1.235
    let zero: decimal = 0.0
    let negative_half: decimal = zero - 2.5
    let negative_low: decimal = zero - 2.1
    let negative_high: decimal = zero - 2.9

    io.println("{two_half.round(0)} {three_half.round(0)} {negative_half.round(0)}")
    io.println("{two_half.round(0, RoundingMode.half_away)} {negative_half.round(0, RoundingMode.half_away)}")
    io.println("{negative_high.round(0, RoundingMode.toward_zero)} {negative_low.round(0, RoundingMode.floor)} {negative_high.round(0, RoundingMode.ceil)}")
    io.println("{one_low.round(2)} {one_high.round(2)}")
    let two: decimal = 2
    let three: decimal = 3
    io.println("{two / three} {(zero - two) / three}")
    io.println("{two.round(0 - 9223372036854775807)}")
    let parsed: decimal = "12.5".to_decimal().or(7.25)
    let fallback: decimal = "not a decimal".to_decimal().or(7.25)
    io.println("{parsed} {fallback}")
}

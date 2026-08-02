// The 38-digit decimal contract, re-audited 2026-07-28: exactness,
// boundary literals, all five rounding modes at signed ties, division
// to 38 significant digits with a half-even tail, checked casts,
// formatting, and string parsing — every line must answer identically
// in the interpreter and both native backends. The audit that wrote
// this found Decimal::parse accepting any character as a digit
// ("nan" became coefficient 6752) and NaN comparisons disagreeing
// between the backends; those fixes live or die by this file.
import std.io

fn section(name: string) {
    io.println("== {name}")
}

fn show_parse(text: string) {
    match text.to_decimal() {
        ok(value) => { io.println("ok {value}") }
        err(problem) => { io.println("err {problem.msg}") }
    }
}

fn main() {
    section("exactness")
    let tenth: decimal = 0.1
    let fifth: decimal = 0.2
    let target: decimal = 0.3
    io.println("{tenth + fifth == target} {tenth + fifth}")
    let seven_tenths: decimal = 0.7
    let one: decimal = 1.0
    let nine_tenths: decimal = 0.9
    io.println("{tenth + seven_tenths} {one - nine_tenths} {target - tenth}")
    let two_long: decimal = 2.00
    let two_short: decimal = 2.0
    let low: decimal = 1.50
    let high: decimal = 1.51
    io.println("{two_long == two_short} {low < high} {two_short > low}")

    section("boundaries")
    let wide: decimal = 9999999999999999999999999999999999999.9
    let thin: decimal = 0.00000000000000000000000000000000000001
    io.println("{wide}")
    io.println("{thin}")
    let almost: decimal = 9999999999999999999999999999999999999.8
    io.println("{wide - almost}")
    let ten: decimal = 10.0
    io.println("{thin * ten}")
    let grouped: decimal = 1_234_567.89
    io.println("{grouped}")

    section("rounding modes")
    let tie: decimal = 2.5
    let negative_tie: decimal = -2.5
    let odd_tie: decimal = 3.5
    io.println("{tie.round(0)} {odd_tie.round(0)} {negative_tie.round(0)}")
    io.println("{tie.round(0, RoundingMode.half_away)} {negative_tie.round(0, RoundingMode.half_away)}")
    io.println("{tie.round(0, RoundingMode.toward_zero)} {negative_tie.round(0, RoundingMode.toward_zero)}")
    io.println("{tie.round(0, RoundingMode.floor)} {negative_tie.round(0, RoundingMode.floor)}")
    io.println("{tie.round(0, RoundingMode.ceil)} {negative_tie.round(0, RoundingMode.ceil)}")
    let eighth: decimal = 0.125
    let negative_eighth: decimal = -0.125
    io.println("{eighth.round(2)} {eighth.round(2, RoundingMode.half_away)} {negative_eighth.round(2)}")
    let n05: decimal = 0.05
    let n15: decimal = 0.15
    let n25: decimal = 0.25
    let n35: decimal = 0.35
    io.println("{n05.round(1)} {n15.round(1)} {n25.round(1)} {n35.round(1)}")

    section("division")
    let three: decimal = 3.0
    let seven: decimal = 7.0
    let third: decimal = one / three
    io.println("{third}")
    let two: decimal = 2.0
    io.println("{two / three}")
    io.println("{one / seven}")
    let four: decimal = 4.0
    let hundred: decimal = 100.0
    let eight: decimal = 8.0
    let negative_seven: decimal = -7.0
    io.println("{ten / four} {hundred / eight} {negative_seven / two}")
    io.println("{third * three}")

    section("casts")
    let big: int = 9223372036854775807
    let small: int = -9223372036854775807 - 1
    io.println("{big as decimal}")
    io.println("{small as decimal}")
    let nearly_three: decimal = 2.99
    let negative_nearly: decimal = -2.99
    let two_and_half: decimal = 2.5
    io.println("{nearly_three as int} {negative_nearly as int} {two_and_half as int}")
    let half: float = 0.5
    io.println("{half as decimal}")
    let quarter: decimal = 1.25
    io.println("{quarter as float}")

    section("signs")
    let negzero: decimal = -0.0
    let zero: decimal = 0.0
    let negative_one_and_half: decimal = -1.5
    let one_and_half: decimal = 1.5
    io.println("{negzero} {negzero == zero} {negative_one_and_half.abs()} {one_and_half.abs()}")
    let quarter_three: decimal = 3.25
    io.println("{-quarter_three} {-(-quarter_three)}")

    section("formatting")
    let pi: decimal = 3.14159
    io.println("{pi:.2} {pi:.4} {pi:.0}")
    let charge: decimal = 2.675
    let charge_low: decimal = 2.665
    let half_dec: decimal = 0.5
    let one_and_half_dec: decimal = 1.5
    io.println("{charge:.2} {charge_low:.2} {half_dec:.0} {one_and_half_dec:.0}")
    io.println("{one:.4} {ten:.2}")

    section("parsing")
    show_parse("12.50")
    show_parse("1_000.5")
    show_parse("1.5e3")
    show_parse("-0.001")
    show_parse("12x")
    show_parse("nan")
    show_parse("")
    show_parse("1e999999999999999999")
    show_parse("--5")

    section("nan comparisons")
    let zero_f: float = 0.0
    let quiet: float = 0.0 / zero_f
    io.println("{quiet != quiet} {quiet == quiet} {quiet < 1.0} {quiet >= 1.0}")
}

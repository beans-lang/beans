// `19.99 as decimal` is the decimal 19.99. It used to be the decimal nearest
// to the f64 nearest to 19.99, because a decimal-point literal with no demand
// is an f64 and the cast faithfully converted it — the exact mistake decimal
// exists to prevent, in the one spelling that reads like a decimal literal.
//
// The demand stops at the real-number types and at literals: a float variable
// cast to decimal must still say what that float really is, and an integer
// cast to an integer type must still keep the low target-width bits.
import std.io

fn total(price: decimal, qty: decimal) -> decimal {
    return price * qty
}

fn main() {
    // the literal never becomes an f64
    io.println("sum   {(19.99 as decimal) + (0.01 as decimal)}")
    io.println("tenth {(0.1 as decimal) + (0.2 as decimal)}")
    io.println("sig   {total(19.99 as decimal, 3 as decimal)}")
    io.println("neg   {-19.99 as decimal} {-(19.99 as decimal)}")
    io.println("paren {(19.99) as decimal}")
    io.println("exp   {1.5e3 as decimal} {2.5e-3 as decimal}")

    // ...and matches the binding form it reads like
    let bound: decimal = 19.99
    let cents: decimal = 0.01
    io.println("bound {bound + cents} {(19.99 as decimal) + (0.01 as decimal)}")
    io.println("same  {bound == (19.99 as decimal)}")

    // a literal too wide for int is a decimal literal here, not an error
    io.println("wide  {12345678901234567890123456789012345678 as decimal}")

    // a float *value* still tells the truth about itself
    let rate: float = 0.1
    var running: float = 0.0
    running = running + 0.1
    io.println("value {rate as decimal} {running as decimal}")

    // integer targets keep the wrapping rule
    io.println("wrap  {300 as i8} {-1 as u8} {200 as u8} {65536 as u16}")

    // float targets take the demand too, and an integer literal is exact there
    io.println("float {19.99 as float} {19.99 as f32} {3 as float}")

    // a hex or binary literal is the integer it spells, everywhere
    let hexf: float = 0xFF
    let hexd: decimal = 0xFF
    let binf: f32 = 0b101
    io.println("base  {hexf} {hexd} {binf} {0xFF as decimal} {0b1010 as float} {0x10 as f32}")
    io.println("negb  {-0xFF as decimal} {-0b101 as float}")

    // int.min's magnitude is one past int.max, the one value the fit check
    // admits only with its sign — the digits must not wrap on the way through
    let minf: float = -0x8000000000000000
    let mind: decimal = -0x8000000000000000
    io.println("minb  {minf} {mind} {-0x8000000000000000 as f32}")
    io.println("minx  {-0x8000000000000000 as float} {-0x8000000000000000 as decimal}")
    io.println("minn  {-0b1000000000000000000000000000000000000000000000000000000000000000 as decimal}")

    // and a float literal cast to an integer still truncates
    io.println("trunc {19.99 as int} {-19.99 as int} {19.99 as i8}")
}

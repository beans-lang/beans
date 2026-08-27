// Scale is part of a decimal's answer, not decoration: money is written with
// its cents whether or not they are zero. Two things used to lose it — adding
// to a zero, and a compound assignment to a field, which the native backend
// refused outright while the checker and the interpreter took it.
import std.io

class Ledger {
    pub total: decimal = 0.00
    pub fn add(amount: decimal) { self.total += amount }
    pub fn refund(amount: decimal) { self.total -= amount }
    pub fn apply(factor: decimal) { self.total *= factor }
    pub fn split(parts: decimal) { self.total /= parts }
}

fn main() {
    // a zero carries a scale, and a sum takes the wider of the two
    let zero0: decimal = 0
    let zero2: decimal = 0.00
    let zero4: decimal = 0.0000
    let whole: decimal = 233
    let half: decimal = 1.5
    io.println("zero left {zero2 + whole} {zero4 + half} {zero2 - whole}")
    io.println("zero right {whole + zero2} {half - zero4}")
    io.println("both zero {zero0 + zero2} {zero2 + zero4}")
    io.println("through mul {zero2 * whole} {zero0 * whole}")

    // the shape every ledger starts with
    var running: decimal = 0.00
    running += 5
    running += 10
    io.println("running {running}")

    // scale where neither side is zero, which always worked
    let a: decimal = 19.99
    let b: decimal = 0.01
    let c: decimal = 1.50
    io.println("plain {a + b} {c + whole} {c * c}")

    // a compound assignment to a field, every operator, both backends
    let led: Ledger = new Ledger()
    led.add(19.99)
    led.add(b)
    io.println("field add {led.total}")
    led.refund(4.00)
    io.println("field sub {led.total}")
    led.apply(2.0)
    io.println("field mul {led.total}")
    led.split(4.0)
    io.println("field div {led.total}")

    // scale never changes what a decimal is worth, or where it hashes
    let padded: decimal = 233.00
    io.println("equal {zero0 == zero2} {padded == whole}")
    var keyed: Map<decimal, string> = {}
    keyed.set(zero2, "zero")
    io.println("one key {keyed.len()} {keyed.get(zero0).or("MISSING")}")
}

import std.io
import std.fmt

struct Price {
    amount: decimal
    label: string
}

class Ledger {
    balance: decimal
    name: string

    fn init(move name: string) {
        self.name = move name
        self.balance = 0.00
    }

    fn deposit(amount: decimal) {
        self.balance = self.balance + amount
    }

    fn describe() -> string {
        return "{self.name}: {self.balance}"
    }
}

fn parse_price(text: string) -> Result<decimal> {
    let value: decimal = text.to_decimal()?
    return ok(value * 2.0)
}

fn main() {
    let a: decimal = 1.50
    let b: decimal = 2.5e1
    let c: decimal = 1_000.25
    io.println("{a} {b} {c}")
    io.println("sum {a + b} diff {a - b} product {a * b} quotient {b / a}")
    io.println("compare {a < b} {a == 1.5} {a != b} {b >= 25} {a <= 1.49} {b > 24.9}")
    let negated: decimal = -a
    let restored: decimal = negated.abs()
    io.println("neg {negated} abs {restored}")
    let precise: decimal = 2.345
    io.println("round {precise.round(2)} {precise.round(2, RoundingMode.half_away)}")
    let half: decimal = 2.5
    io.println("modes {half.round(0, RoundingMode.floor)} {half.round(0, RoundingMode.ceil)} {half.round(0, RoundingMode.toward_zero)}")
    let n: int = 42
    let widened: decimal = n as decimal
    let fee: decimal = 9.99
    let clipped: int = fee as int
    let floating: float = half as float
    let back: decimal = 0.5 as decimal
    io.println("cast {widened} {clipped} {floating} {back}")
    var ledger: Ledger = new Ledger("savings")
    ledger.deposit(10.05)
    ledger.deposit(0.95)
    io.println(ledger.describe())
    let price: Price = Price { amount: 19.90, label: "boots" }
    io.println("{price.label} cost {price.amount}")
    match "12.5".to_decimal() {
        ok(parsed) => { io.println("parsed {parsed}") }
        err(problem) => { io.println("bad {problem.msg}") }
    }
    match "sideways".to_decimal() {
        ok(parsed) => { io.println("parsed {parsed}") }
        err(problem) => { io.println("bad {problem.msg}") }
    }
    io.println("fallback {"nope".to_decimal().or(0.25)}")
    match parse_price("3.5") {
        ok(doubled) => { io.println("doubled {doubled}") }
        err(problem) => { io.println("failed {problem.msg}") }
    }
    match parse_price("oops") {
        ok(doubled) => { io.println("doubled {doubled}") }
        err(problem) => { io.println("failed {problem.msg}") }
    }
    let exact: decimal = "7.25".to_decimal().expect("must parse")
    io.println("expected {exact}")
    io.println("formatted {fmt.decimal(a, 4)}")
}

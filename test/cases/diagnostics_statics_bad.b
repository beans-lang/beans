import std.io

class Gap {
    static s2: int = 8
    static s2p5: int = 10

    static fn twice(n: int) -> int {
        return n * 2
    }
}

enum Payment {
    cash
    card(number: string)
}

fn main() {
    // the field name is the mistake; the type resolved fine
    io.println("{Gap.s2p}")
    // a static method named as a value, not called
    let f: fn(int) -> int = Gap.twice
    io.println("{f(1)}")
    // an enum variant that does not exist
    let p: Payment = Payment.cast
    io.println("{p}")
}

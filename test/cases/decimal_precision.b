import std.io

fn main() {
    let max: decimal = 99999999999999999999999999999999999999
    let factor: decimal = 9999999999999999999
    let exact_product: decimal = factor * factor
    let one: decimal = 1
    let tie_even: decimal =
        one + 0.00000000000000000000000000000000000005
    let tie_odd: decimal =
        one + 0.00000000000000000000000000000000000015
    let third: decimal = one / 3

    io.println("{max}")
    io.println("{exact_product}")
    io.println("{tie_even}")
    io.println("{tie_odd}")
    io.println("{third}")
    io.println("{"1e-4096".to_decimal().expect("scale") > 0}")
    match "999999999999999999999999999999999999999".to_decimal() {
        ok(value) => io.println("unexpected {value}"),
        err(_) => io.println("39 digits rejected"),
    }
}

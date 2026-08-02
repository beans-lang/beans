// Calling a raw address outside unsafe. The signature is the caller's guess, and a wrong
// guess corrupts the stack rather than raising anything — so the checker refuses it.
import std.dl
fn main() {
    let result: int = dl.call0(4096)
}

// Resolving is deliberately *not* unsafe: holding an address is harmless, and requiring
// unsafe here would train callers to wrap the safe part too.
import std.dylib
fn go() -> Result<int> {
    let lib: dylib.Dylib = dylib.Dylib.open("/nonexistent")?
    let s: dylib.Symbol = lib.find("anything")?
    return ok(s.address)
}
fn main() { let x: Result<int> = go() }

// A library handle is move-only, so it cannot be dlclose'd twice.
import std.dylib
fn go() -> Result<bool> {
    let lib: dylib.Dylib = dylib.Dylib.open("/nonexistent")?
    let alias: dylib.Dylib = lib
    return ok(alias.has("x"))
}
fn main() { let x: Result<bool> = go() }

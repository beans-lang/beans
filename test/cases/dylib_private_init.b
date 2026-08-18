// Fabricating a library handle from a raw number would let a caller dlclose something
// the real handle still owns.
import std.dylib
fn main() {
    let fake: dylib.Dylib = new dylib.Dylib(1, "made up")
}

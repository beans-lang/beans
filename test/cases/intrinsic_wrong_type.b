// Every row states its exact signature. An int literal adapts to a float, as
// anywhere else in the language, but a string does not.
import std.intrinsic
fn main() {
    unsafe {
        let v: float = intrinsic.sqrt("16")
    }
}

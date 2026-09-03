// A brace someone meant literally reads as an interpolation; the error says
// so and points at the escape and the raw literal, instead of only "unknown
// name".
import std.io
fn main() {
    io.println("/users/{id}")
}

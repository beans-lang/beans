// The byte and codepoint escapes name their own mistakes: an unknown escape,
// a short \x, an unbraced \u, and a codepoint that has no UTF-8 form.
import std.io
fn main() {
    io.println("unknown \d here")
    io.println("short \x1 here")
    io.println("unbraced \u12 here")
    io.println("toobig \u{110000} here")
    io.println("surrogate \u{d800} here")
}

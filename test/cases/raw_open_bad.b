// `r` is a raw prefix only when it starts a token. At the top level the
// lexer keeps that by scanning a whole name first, so `str"…"` is a name
// and a string. Inside an interpolation the lexer walks byte by byte, and
// when it tested for `r"` without that rule it consumed `r#"a"b}c"#` as a
// raw literal while every walker re-reading the token read `#"a"` as a
// nested string and ended the slot at the `}`. One token, two structures.
// Now both stop in the same place, so the error is one lexer error and not
// a piece the checker split somewhere the lexer never did.
import std.io

fn main() {
    io.println("{ ptr#"a"b}c"# }")
}

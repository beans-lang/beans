// There is no `+` for strings (spec/SYNTAX.md, "Strings"). The checker took
// it anyway and the tree interpreter joined the two, so every line below
// passed `beansc check`, printed an answer under `beansc run`, and only met
// the rule at `beansc build` — as a message about the LLVM emitter rather
// than about the program (issue #133).
//
// One shape proves nothing here: the accepting branch sat in check_binary
// and so was reached by every position an expression can occupy. Each line
// is a different one, and test/language_gaps.sh counts the errors, so a
// shape that starts slipping through again fails this rather than quietly
// widening the hole.
import std.io

class Holder {
    // a static field initializer — an expression checked outside any
    // function body
    static tag: string = "a" + "b"
    s: string
    fn init(s: string) { self.s = s }
    // the right side of a field write, where the field is also an operand
    fn grow(extra: string) { self.s = self.s + extra }
}

// a return position
fn joined(a: string, b: string) -> string { return a + b }

fn emit(text: string) { io.println(text) }

fn main() {
    let a: string = "x"
    let b: string = "y"
    let h: Holder = new Holder("z")
    io.println(a + b)                       // two locals
    io.println("x" + "y")                   // two literals
    io.println(h.s + b)                     // field plus local
    io.println(joined(a, b))
    emit(a + "y")                           // an argument
    io.println("{a + b}")                   // inside an interpolation
    let list: List<string> = [a + b]        // a list element
    io.println(list[0])
    var acc: string = a
    acc = acc + b                           // the right side of an assignment
    io.println(acc)
    let map: Map<string, string> = {(a + b): (b + a)}
    io.println(map["xy"])
    if (a + b) == "xy" { io.println("compared") }
    for piece: string in [a + b] { io.println(piece) }
    h.grow("w")
    io.println(Holder.tag)
    // the same mistake written with a non-string on one side: `+` is still
    // not what joins these, and the message has to name the string
    io.println("{a + 1}")
    io.println("{1 + a}")
}

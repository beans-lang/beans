// Phi joins through the self-host LLVM emitter. Every phi lowers to
// a stack slot stored on the taken edge: a real LLVM phi would name
// values from blocks that are not emitted yet — `a && (b || c)`
// joins on a value defined two blocks later in block order, which
// is exactly the shape that broke.
import std.io

fn classify(source: string, start: int) -> string {
    if start < source.len() &&
       (source.byte_at(start) == 43 ||
        source.byte_at(start) == 45) {
        return "signed"
    }
    return "plain"
}

fn main() {
    io.println("e+5 at 1 is {classify("e+5", 1)}")
    io.println("e5 at 1 is {classify("e5", 1)}")
    io.println("e-2 at 1 is {classify("e-2", 1)}")
    io.println("e+5 at 9 is {classify("e+5", 9)}")

    let flag: bool = true
    let word: string = if flag { "yes" } else { "no" }
    io.println("picked {word}")

    var tail: string = "start"
    for step: int in 0..3 {
        tail = if step % 2 == 0 { "even {step}" } else { "odd {step}" }
    }
    io.println("ended {tail}")

    var count: int = 0
    for candidate: int in 0..10 {
        if candidate % 2 == 0 && (candidate % 3 == 0 || candidate == 4) {
            count += 1
        }
    }
    io.println("matched {count}")
}

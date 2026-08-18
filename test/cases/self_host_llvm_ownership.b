// Two ownership traps the stage-2 bootstrap surfaced, kept here so
// they stay fixed. First: releasing a temporary list on the index
// that borrows out of it frees the element before its retain —
// the release must sink past the borrow's use. Second: a closure
// capturing a reference-typed parameter stores it in an owning
// cell, so it must retain going in or every call steals one count
// from the caller's object.
import std.io

class Info {
    label: string

    fn init(label: string) {
        self.label = label
    }
}

fn make_infos() -> List<Info> {
    return [new Info("first"), new Info("second")]
}

fn shout(subject: Info, times: int) -> string {
    var line: string = ""
    let speak: fn(int) -> string = fn(round: int) -> string {
        return "{subject.label}#{round}"
    }
    for round: int in 0..times {
        line = speak(round)
    }
    return line
}

fn main() {
    let chosen: Info = make_infos()[0]
    io.println("chosen {chosen.label}")

    let keep: Info = new Info("durable")
    for pass: int in 0..4 {
        io.println(shout(keep, pass + 1))
    }
    io.println("still {keep.label}")
}

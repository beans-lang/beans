// Driven by test/term.sh under a pseudo-terminal: enters raw mode, reports what
// the terminal is, then decodes the keystrokes the harness feeds until a NUL
// byte ends the stream, and restores. All output is unbuffered through the
// module's own write path, so nothing sits in a stdio buffer waiting on a
// newline that never comes.
import std.term
import std.proc

fn say(line: string) {
    var b: Bytes = new Bytes(0)
    b.append_string(line)
    b.push(10)
    let ignored: Result<int> = term.write_all(1, b)
}

fn main() {
    match term.RawMode.enter(0) {
        ok(raw) => {
            say("tty={term.is_tty(0)}")
            match term.size(0) {
                ok(size) => { say("size={size.rows}x{size.cols}") }
                err(problem) => { say("size-err={problem.msg}") }
            }
            say("READY")
            var decoder: term.KeyDecoder = new term.KeyDecoder()
            var done: bool = false
            for !done {
                match proc.read(0, 64) {
                    ok(chunk) => {
                        if chunk.len() == 0 {
                            done = true
                        }
                        var cut: int = chunk.len()
                        var index: int = 0
                        var found: bool = false
                        for index < chunk.len() && !found {
                            if chunk.get(index) == 0 {
                                cut = index
                                found = true
                                done = true
                            }
                            index += 1
                        }
                        decoder.feed(chunk.slice(0, cut))
                        var going: bool = true
                        for going {
                            match decoder.next() {
                                some(key) => { say("key {key}") }
                                none => { going = false }
                            }
                        }
                    }
                    err(problem) => { done = true }
                }
            }
            match decoder.flush() {
                some(key) => { say("key {key}") }
                none => {}
            }
            let restored: Result<bool> = raw.restore()
            say("done fd={raw.descriptor()}")
        }
        err(problem) => { say("raw-err={problem.msg}") }
    }
}

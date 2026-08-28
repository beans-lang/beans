// Driven by test/term.sh: enters raw mode and then panics, on purpose. A native
// panic exits through exit(3) without unwinding, so the guard's deinit never
// runs — the only thing that restores the terminal is the runtime's atexit
// handler. The harness checks the terminal is cooked again after this dies,
// which is the regression test for that handler. `raw` is used after the panic
// point so the guard is alive when the panic fires, never dropped before it.
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
            say("READY fd={raw.descriptor()}")
            var one: List<int> = [1]
            var past: int = 5
            let boom: int = one[past]
            say("unreachable {boom}")
            let restored: Result<bool> = raw.restore()
            say("also unreachable {raw.descriptor()}")
        }
        err(problem) => { say("raw-err={problem.msg}") }
    }
}

// Verify the runtime's atexit handler restores raw terminal mode after a panic.





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

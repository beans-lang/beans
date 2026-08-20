import std.io
import std.log

fn main() {
    match log.Sink.file("minimal.log") {
        ok(_) => { io.println("unexpected file sink") }
        err(problem) => {
            io.println("{problem.kind}: {problem.msg}")
        }
    }
}

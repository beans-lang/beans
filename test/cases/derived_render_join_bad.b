// join renders each element the way interpolation does, so an element with
// no string form has to be refused at check time — not by an emitter after
// the tree interpreter has already printed it.
import std.io
import std.thread
fn main() {
    var workers: List<Thread<int>> = []
    workers.push(thread.spawn(fn() -> int { return 1 }))
    io.println(workers.join(", "))
}

// A class carrying a field no backend can render (a thread handle) is not
// printable: give it a string form first.
import std.io
import std.thread
class Holder {
    worker: Thread<int>
    fn init(worker: Thread<int>) { self.worker = worker }
}
fn main() {
    let h: Holder = new Holder(thread.spawn(fn() -> int { return 1 }))
    io.println("{h}")
    h.worker.join()
}

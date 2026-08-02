// Threads need a hosted platform, so freestanding does not have them.
import std.io
import std.thread
fn main() {
    let t: Thread<int> = thread.spawn(fn() -> int { return 7 })
    io.println("{t.join()}")
}

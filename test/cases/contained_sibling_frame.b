// The catch-frame count is asked of a fiber, never of the thread (issue #145).
//
// This is the program that tells the two apart, and it is the only shape that
// can: the count is read to decide whether a panic unwinds at all, and a
// brewed fiber always unwinds anyway — so the difference only shows on the
// ROOT fiber, which unwinds only when a frame of its own is standing.
//
// A brewed child opens a catch frame and parks inside it. The root then panics
// with no frame of its own. That panic is uncontained: it must abandon its
// frames — no defer, no deinit — print the ordinary report and exit 3.
//
// With a per-thread count the root reads the child's frame and unwinds instead:
// the tree walker runs the root's defers and drops its locals, and the native
// build walks its cleanup pads and then reaches the end of the stack, where the
// runtime says the catch could not be found. Either way the output changes.
import std.io
import std.time

class Res {
    pub tag: string
    fn init(tag: string) { self.tag = tag }
    fn deinit() { io.println("drop {self.tag}") }
}

fn parks(millis: int) -> int {
    time.sleep_millis(millis)
    return 1
}

// The child stands inside a catch frame for the whole of the root's failure.
fn child_holds_a_frame() -> int {
    match contained parks(4000) {
        ok(v) => { return v }
        err(p) => { return -1 }
    }
}

fn root_fails() -> int {
    let held: Res = new Res("root-held")
    defer io.println("root defer")
    panic("the root fails while a child's frame stands")
}

fn main() {
    let child: Brew<int> = brew child_holds_a_frame()
    // Long enough for the child to reach its park inside the frame.
    time.sleep_millis(80)
    io.println("child is parked inside its catch frame")
    let ignored: int = root_fails()
    io.println("unreachable")
}

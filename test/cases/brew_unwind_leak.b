// The contained-panic unwind reclaims everything the fiber owned (issue #44).
// Each shielded call brews a fiber that allocates a heap buffer, arms a defer,
// and panics while still holding the buffer; the panic is caught at the join.
// If the unwind drops the buffer — as a return would — nothing accumulates
// across two hundred contained panics, and `leaks` reports zero. A missed drop
// leaks a 64 KiB block per panic, which the sweep catches. This is the
// resource-exhaustion shape from the issue (a handler that panics on bad input
// must cost one request, not the process), reduced to a deterministic program.
import std.io

class Buffer {
    pub data: Bytes
    pub tag: int
    fn init(size: int, tag: int) {
        self.data = new Bytes(size)
        self.tag = tag
    }
    // The Bytes field is released when this object drops; the drop must happen
    // on the unwind path, not only on a normal return.
    fn deinit() {}
}

fn holds(size: int, tag: int) -> int {
    let buf: Buffer = new Buffer(size, tag)
    let scratch: List<int> = [buf.tag, size]
    defer io.eprint("")
    let empty: List<int> = []
    return empty[0]
}

fn shielded(size: int, tag: int) -> bool {
    let child: Brew<int> = brew holds(size, tag)
    match child.join() {
        ok(v) => { return false }
        err(problem) => { return true }
    }
}

fn main() {
    var i: int = 0
    var caught: int = 0
    for i < 200 {
        if shielded(65536, i) { caught += 1 }
        i += 1
    }
    io.println("contained {caught} panics, each held a 64 KiB buffer")
}

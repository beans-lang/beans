// The contained-panic unwind reclaims everything the fiber owned (issue #44).
// Each shielded call brews a fiber that allocates a heap buffer, arms a defer,
// and panics while still holding the buffer; the panic is caught at the join.
// If the unwind drops the buffer — as a return would — nothing accumulates
// across two hundred rounds of three contained panics, and `leaks` reports
// zero. A missed drop leaks a 64 KiB block per panic, which the sweep catches.
// The three shapes: a local holding the buffer, a temporary holding it (built
// as one argument while the next argument panics), and an object whose init
// took it and then panicked. This is the
// resource-exhaustion shape from the issue (a handler that panics on bad input
// must cost one request, not the process), reduced to a deterministic program.
import std.io

class Buffer {
    pub data: Bytes
    pub tag: int
    // filled, not merely allocated: an untouched allocation is never
    // resident, and the resident set is what the macOS sweep measures
    fn init(size: int, tag: int) {
        self.data = Bytes.filled(size, 7)
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

// A temporary in flight when the panic lands: the buffer argument has been
// built and is owned by nobody's local when the second argument panics.
fn accept(buf: Buffer, n: int) -> int { return n }
fn fails(size: int) -> int { let empty: List<int> = []; return empty[size] }
fn holds_temporary(size: int, tag: int) -> int {
    return accept(new Buffer(size, tag), fails(size))
}

// A half-built object: init has taken its buffer when it panics.
class Late {
    pub data: Bytes
    pub extra: Bytes
    fn init(size: int) {
        self.data = Bytes.filled(size, 7)
        let empty: List<int> = []
        let unused: int = empty[size]
        self.extra = Bytes.filled(size, 7)
    }
}
fn holds_half_built(size: int) -> int {
    let late: Late = new Late(size)
    return 1
}

fn shielded_temporary(size: int, tag: int) -> bool {
    let child: Brew<int> = brew holds_temporary(size, tag)
    match child.join() {
        ok(v) => { return false }
        err(problem) => { return true }
    }
}

fn shielded_half_built(size: int) -> bool {
    let child: Brew<int> = brew holds_half_built(size)
    match child.join() {
        ok(v) => { return false }
        err(problem) => { return true }
    }
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
        if shielded_temporary(65536, i) { caught += 1 }
        if shielded_half_built(65536) { caught += 1 }
        i += 1
    }
    io.println("contained {caught} panics, each held a 64 KiB buffer")
}

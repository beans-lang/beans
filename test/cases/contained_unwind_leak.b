// A panic caught at a call boundary reclaims everything the call owned
// (issue #145). Same stress as brew_unwind_leak, one frame earlier: the
// failure stops at a `contained` call instead of at a fiber entry, so the
// unwind pads have to drop the same things and the catch pad has to leave the
// caller's frame consistent. Two hundred rounds of four shapes, each holding a
// filled 64 KiB buffer, is 800 caught panics; a missed drop leaks 64 KiB per
// panic, which ASan/LeakSanitizer reports and the macOS resident-set witness
// catches.
//
// The four shapes:
//   * a local holding the buffer behind an armed defer;
//   * a temporary holding it — built as one argument while the next argument
//     panics, so it belongs to no local when the unwind starts;
//   * an object whose init took it and then panicked (no deinit body runs, but
//     the field it did assign must still drop);
//   * the contained call's own hoisted arguments, which ride in a closure box
//     this frame owns: the box must be released on the caught path, not only
//     on the path where the call returned.
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
    fn deinit() {}
}

fn holds(size: int, tag: int) -> int {
    let buf: Buffer = new Buffer(size, tag)
    let scratch: List<int> = [buf.tag, size]
    defer io.eprint("")
    let empty: List<int> = []
    return empty[0]
}

fn accept(buf: Buffer, n: int) -> int { return n }
fn fails(size: int) -> int { let empty: List<int> = []; return empty[size] }
fn holds_temporary(size: int, tag: int) -> int {
    return accept(new Buffer(size, tag), fails(size))
}

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

// The buffer arrives as an argument, so it is hoisted into the closure box the
// contained call carries. The callee panics without ever taking it, which
// leaves the box the only owner — and the box is this frame's to release, on
// the caught path as much as on the returning one.
fn refuses(buf: Buffer, size: int) -> int {
    let empty: List<int> = []
    return empty[size]
}

fn caught(size: int, tag: int) -> bool {
    match contained holds(size, tag) {
        ok(v) => { return false }
        err(problem) => { return true }
    }
}

fn caught_temporary(size: int, tag: int) -> bool {
    match contained holds_temporary(size, tag) {
        ok(v) => { return false }
        err(problem) => { return true }
    }
}

fn caught_half_built(size: int) -> bool {
    match contained holds_half_built(size) {
        ok(v) => { return false }
        err(problem) => { return true }
    }
}

fn caught_hoisted(size: int, tag: int) -> bool {
    match contained refuses(new Buffer(size, tag), size) {
        ok(v) => { return false }
        err(problem) => { return true }
    }
}

fn main() {
    var i: int = 0
    var count: int = 0
    for i < 200 {
        if caught(65536, i) { count += 1 }
        if caught_temporary(65536, i) { count += 1 }
        if caught_half_built(65536) { count += 1 }
        if caught_hoisted(65536, i) { count += 1 }
        i += 1
    }
    io.println("caught {count} panics at a call boundary, each held a 64 KiB buffer")
}

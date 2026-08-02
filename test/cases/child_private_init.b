// Fabricating a Child from a raw pid would let a caller signal and reap a process the
// real handle still owns — or one that belongs to somebody else entirely.
import std.process
fn main() {
    let fake: process.Child = new process.Child(1, new process.Stream(0, "in"),
                                                new process.Stream(1, "out"),
                                                new process.Stream(2, "err"))
}

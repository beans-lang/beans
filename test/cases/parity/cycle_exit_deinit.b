// #91: a generic class holding a generic class field skipped its cycle deinits
// at exit under the tree interpreter, where the native backend ran them. Both
// ingredients are needed -- the owner is generic AND holds a class-typed field
// with a `new()` initializer -- and the failure is exit-specific: a cycle the
// collector sweeps at the end of the process. The two backends consumed the
// same checked program and disagreed about whether user code ran at all.
//
// The shared root with #96: an object with a deinit took a host wrapper whose
// teardown released the object's fields by hand, and for a cycle that by-hand
// release re-entered the collector's own deinit pass (releasing a member's
// cross-edges to the other members it was mid-sweep on), which corrupted the
// pass and skipped the bodies. Handing field release to the host cascade -- the
// collector's own beans_release loop, which frees cycle members correctly --
// runs every body.
//
// The owner `o` is acyclic and shared by every watcher, so its count is 2 the
// whole time. Encoding that count in the release marker makes this catch three
// failures at once: a skipped deinit prints no `arc-` line at all (markers do
// not balance), and the "second face" of the same bug -- a deinit that runs
// against an owner whose fields were already stripped -- would read a different
// count or panic. n = 1 is a watcher pointing at itself, n = 2 is the issue's
// repro, n = 5 is a longer ring: one skipped shape at any size fails here.
package main

import std.io

class Inner<T implements Clone> {
    rows: List<T> = []
    fn init() {}
}

class Owner<T implements Clone> {
    inner: Inner<T> = new()
    fn init() {}
    pub fn count() -> int { return self.inner.rows.len() }
    pub fn add(v: T) { self.inner.rows.push(v) }
}

class Watcher {
    peer: Option<Watcher> = none
    owner: Option<Owner<int>> = none

    fn init(o: Owner<int>) {
        self.owner = some(o)
        io.println("arc+w{o.count()}")
    }

    fn deinit() {
        match self.owner {
            some(o) => { io.println("arc-w{o.count()}") }
            none => { io.println("arc-w?") }
        }
    }
}

// A ring of `n` watchers, each holding the shared owner: a garbage cycle only
// the collector can free.
fn ring(o: Owner<int>, n: int) -> List<Watcher> {
    var r: List<Watcher> = []
    for i: int in 0..n { r.push(new Watcher(o)) }
    for i: int in 0..n { r[i].peer = some(r[(i + 1) % n]) }
    return move r
}

fn main() {
    let o: Owner<int> = new Owner<int>()
    o.add(1)
    o.add(2)
    // Kept alive until main returns, so the rings are swept at exit -- the path
    // the interpreter skipped -- not mid-run.
    let r1: List<Watcher> = ring(o, 1)
    let r2: List<Watcher> = ring(o, 2)
    let r5: List<Watcher> = ring(o, 5)
    io.println("built {r1.len() + r2.len() + r5.len()}")
}

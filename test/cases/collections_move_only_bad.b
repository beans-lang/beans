// A move-only element cannot live in a collection that hands copies back out.
// The bound is Clone; Bytes is not Clone; the checker must say so at the type,
// not leave it to the native emitter.
import std.collections
fn main() {
    var s: collections.Set<Bytes> = new()
    var d: collections.Deque<Bytes> = new()
    var m: collections.SortedMap<int, Bytes> = new()
}

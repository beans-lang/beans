// A SortedMap orders its keys with `<`, which only the primitives support.
// A class key has no `<` to lower to, so it is refused at the type — the
// interpreter would otherwise panic and the native emitter would fail talking
// about itself.
import std.collections
class Key { rank: int = 0 }
fn main() {
    var m: collections.SortedMap<Key, int> = new()
    var q: collections.PriorityQueue<Key, int> = new()
}

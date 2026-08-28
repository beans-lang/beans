// Set<int> and Set<string> over their whole surface: fill with random keys,
// probe membership across the whole range, remove half, then the set algebra
// on two overlapping sets, then the same again with string keys. The algebra
// walks the backing maps directly (std.collections.Set), so this row measures
// that path against std::unordered_set, not a key-list copy.
import std.io
import std.os
import std.collections

fn main() {
    let args: List<string> = os.args()
    let n: int = args.get(0).or("").to_int().or(1_000_000)
    let seed: int = args.get(1).or("").to_int().or(1)
    var x: int = 1 + (seed % 2147483646)

    var s: collections.Set<int> = new()
    var added: int = 0
    var i: int = 0
    for i < n {
        x = (x * 48271) % 2147483647
        if s.add(x % (n * 2)) { added += 1 }
        i += 1
    }

    var hits: int = 0
    i = 0
    for i < n * 2 {
        if s.contains(i) { hits += 1 }
        i += 1
    }

    var removed: int = 0
    i = 0
    for i < n {
        if s.remove(i * 2) { removed += 1 }
        i += 1
    }

    var a: collections.Set<int> = new()
    var b: collections.Set<int> = new()
    i = 0
    for i < n / 4 {
        a.add(i)
        b.add(i + n / 8)
        i += 1
    }
    let u: collections.Set<int> = a.union_with(b)
    let inter: collections.Set<int> = a.intersection(b)
    let diff: collections.Set<int> = a.difference(b)
    let sym: collections.Set<int> = a.symmetric_difference(b)
    let sub: bool = inter.is_subset_of(a)

    var names: collections.Set<string> = new()
    i = 0
    for i < n / 4 {
        names.add("key-{i % (n / 8)}")
        i += 1
    }
    var shits: int = 0
    i = 0
    for i < n / 4 {
        if names.contains("key-{i}") { shits += 1 }
        i += 1
    }

    let checksum: int = added * 7 + hits * 11 + removed * 13 + s.len() * 17 +
        u.len() * 19 + inter.len() * 23 + diff.len() * 29 + sym.len() * 31 +
        (if sub { 1 } else { 0 }) + shits * 37 + names.len() * 41
    io.println("sets {checksum}")
}

// Set<int> and Set<string> over their whole surface: fill with random keys,
// probe membership across the whole range, remove half, then the set algebra
// on two overlapping sets, then the same again with string keys. The algebra
// walks the backing maps directly (std.collections.Set), so this row measures
// that path against std::unordered_set, not a key-list copy.
import std.io
import std.os
import std.collections

// The two algebra sets are built from an index, and a bare index would be a
// gift to the C++ side. `std::hash<int64_t>` is the identity, so consecutive
// keys land in consecutive buckets and never collide with each other; libc++
// goes further and skips the modulo altogether, because `__constrain_hash`
// answers `h < bucket_count() ? h : h % bucket_count()`. Measured on libc++ at
// n = 1,000,000, all 250,000 keys took that no-modulo path and no bucket ever
// held more than one key — std::unordered_set was a direct-index array — while
// Beans ran mix64 on every one of them.
//
// `scatter` is a bijection on [0, 2^40): a multiply by an odd constant modulo
// 2^40, then an xor-shift finalizer. Both sides run the identical function on
// the identical indices, so `a` and `b` hold exactly the members they held
// before under another name — the sizes, the overlap and every count in the
// checksum are unchanged, and the row's expected hash did not move — but the
// keys now sit far above any bucket count, and they hash into a distribution
// indistinguishable from a random one (54.5% empty buckets, against 54.5% for
// keys drawn from std::mt19937_64 and 54.5% for the Poisson ideal).
fn scatter(index: int) -> int {
    let mixed: int = (index * 2654435761) & 1099511627775
    return mixed ^ (mixed >> 20)
}

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
        a.add(scatter(i))
        b.add(scatter(i + n / 8))
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

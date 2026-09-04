// #117: a payload-free enum satisfies `Order`, so sort, max, min and a
// generic `T implements Order` body work on it — by the declaration-order
// tag, the number `enum(u8)` already exposes and `bool`'s false-before-true
// uses, with no representation change and without making a bare `a < b` on
// two enum values legal (that stays refused, as it is for bool).
//
// The two enum shapes have different native representations, which is where a
// backend split hides: a plain enum value is a pointer at its tag word, an
// `enum(u8)` value is the bare tag. The interpreter carries the tag on the
// value; the native sort loads it (runtime kind 7) for a plain enum and reads
// the slot (kind 5) for an `enum(u8)`, and the generic `<` loads the i64 tag
// or compares the i8. All three legs — interpreter, debug, release — must
// answer the same bytes.
//
// Big is an `enum(u8)` of 200 variants: its tags cross 127, where a signed i8
// compare would sort b128..b199 before b0. That is the case n=1 or a handful
// of variants never proves.
package main

import std.io

enum Suit { clubs, hearts, spades }
enum(u8) Rank { bronze, silver, gold }
enum(u8) Big { b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12, b13, b14, b15, b16, b17, b18, b19, b20, b21, b22, b23, b24, b25, b26, b27, b28, b29, b30, b31, b32, b33, b34, b35, b36, b37, b38, b39, b40, b41, b42, b43, b44, b45, b46, b47, b48, b49, b50, b51, b52, b53, b54, b55, b56, b57, b58, b59, b60, b61, b62, b63, b64, b65, b66, b67, b68, b69, b70, b71, b72, b73, b74, b75, b76, b77, b78, b79, b80, b81, b82, b83, b84, b85, b86, b87, b88, b89, b90, b91, b92, b93, b94, b95, b96, b97, b98, b99, b100, b101, b102, b103, b104, b105, b106, b107, b108, b109, b110, b111, b112, b113, b114, b115, b116, b117, b118, b119, b120, b121, b122, b123, b124, b125, b126, b127, b128, b129, b130, b131, b132, b133, b134, b135, b136, b137, b138, b139, b140, b141, b142, b143, b144, b145, b146, b147, b148, b149, b150, b151, b152, b153, b154, b155, b156, b157, b158, b159, b160, b161, b162, b163, b164, b165, b166, b167, b168, b169, b170, b171, b172, b173, b174, b175, b176, b177, b178, b179, b180, b181, b182, b183, b184, b185, b186, b187, b188, b189, b190, b191, b192, b193, b194, b195, b196, b197, b198, b199 }

// The only place the comparison can be written: a bare `a < b` on two enum
// values is refused as an unordered operand, so it goes through a generic
// `Order` body, exactly as bool's does.
fn largest<T implements Order>(a: T, b: T) -> T {
    if a < b { return b }
    return a
}

fn before<T implements Order>(a: T, b: T) -> bool {
    return a < b
}

// all four relational operators, so a mis-mapped predicate (say `>=` emitted
// as `>`) is caught, not just `<`. Answers "lt le " / "gt ge " / "le ge ".
fn relations<T implements Order>(a: T, b: T) -> string {
    var out: string = ""
    if a < b { out = "{out}lt " }
    if a <= b { out = "{out}le " }
    if a > b { out = "{out}gt " }
    if a >= b { out = "{out}ge " }
    return out
}

struct Task { name: string
    prio: Suit }

fn main() {
    // plain enum (pointer / runtime kind 7): sort with duplicates, n=many
    var suits: List<Suit> = [Suit.spades, Suit.clubs, Suit.hearts, Suit.clubs, Suit.spades, Suit.hearts]
    suits.sort()
    io.println("suits: {suits.join(",")}")
    match suits.min() { some(m) => { io.println("suit min: {m}") } none => {} }
    match suits.max() { some(m) => { io.println("suit max: {m}") } none => {} }

    // enum(u8) (slot tag / runtime kind 5)
    var ranks: List<Rank> = [Rank.gold, Rank.bronze, Rank.silver, Rank.bronze]
    ranks.sort()
    io.println("ranks: {ranks.join(",")}")
    match ranks.min() { some(m) => { io.println("rank min: {m}") } none => {} }
    match ranks.max() { some(m) => { io.println("rank max: {m}") } none => {} }

    // the generic body, on each shape
    io.println("largest suit: {largest(Suit.clubs, Suit.spades)}")
    io.println("largest rank: {largest(Rank.bronze, Rank.gold)}")

    // n = 1 and n = 2
    var one: List<Suit> = [Suit.hearts]
    one.sort()
    io.println("n1: {one.join(",")}")
    var two: List<Rank> = [Rank.gold, Rank.bronze]
    two.sort()
    io.println("n2: {two.join(",")}")

    // stability: same-tag records keep input order, and the two backends
    // must pick the same permutation. Routed through a generic Order body,
    // the only place the comparison is legal.
    var tasks: List<Task> = [
        Task { name: "a", prio: Suit.hearts },
        Task { name: "b", prio: Suit.clubs },
        Task { name: "c", prio: Suit.spades },
        Task { name: "d", prio: Suit.hearts },
        Task { name: "e", prio: Suit.clubs },
        Task { name: "f", prio: Suit.hearts }
    ]
    tasks.sort_by(fn(x: Task, y: Task) -> bool { return before(x.prio, y.prio) })
    var names: List<string> = []
    for t: Task in tasks { names.push(t.name) }
    io.println("stable: {names.join(",")}")

    // the tag > 127 boundary: b128..b199 must sort after b0..b127, which a
    // signed i8 compare gets wrong. Duplicates included.
    var big: List<Big> = [Big.b130, Big.b5, Big.b199, Big.b128, Big.b127, Big.b0, Big.b130, Big.b64, Big.b199, Big.b1, Big.b129, Big.b128]
    big.sort()
    io.println("big: {big.join(",")}")
    match big.min() { some(m) => { io.println("big min: {m}") } none => {} }
    match big.max() { some(m) => { io.println("big max: {m}") } none => {} }

    // the same boundary through the generic `<` (a different native path from
    // sort: an icmp on the i8, not slot_cmp). A signed i8 compare reads b130
    // as -126, so it would answer b5 the larger. Both high tags and a
    // high-vs-low pair, so the sign of each operand is exercised.
    io.println("gen largest hi: {largest(Big.b130, Big.b5)}")
    io.println("gen largest hilo: {largest(Big.b64, Big.b199)}")

    // every relational operator, on each enum shape and at the boundary
    io.println("rel suit lo-hi: {relations(Suit.clubs, Suit.spades)}")
    io.println("rel suit eq: {relations(Suit.hearts, Suit.hearts)}")
    io.println("rel rank hi-lo: {relations(Rank.gold, Rank.bronze)}")
    io.println("rel big boundary: {relations(Big.b128, Big.b127)}")
}

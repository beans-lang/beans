// #117, the container half: because a payload-free enum satisfies `Order`, it
// is a legal key for the stdlib's ordered containers, whose bodies compare
// keys through a generic `K implements Order` `<`. That is a different path
// from `List.sort` — a balanced-tree insert and a heap sift, not a merge over
// a slot array — and it has to give the same answer on the interpreter and
// both native builds. A plain enum key (pointer at its tag) and an `enum(u8)`
// key (bare tag) both appear, since their representations differ.
package main

import std.io
import std.collections

enum Suit { clubs, hearts, spades }
enum(u8) Rank { bronze, silver, gold }

fn main() {
    // SortedMap keyed by a plain enum: keys come back in declaration-order
    // tag order regardless of insertion order.
    var sm: collections.SortedMap<Suit, int> =
        new collections.SortedMap<Suit, int>()
    sm.set(Suit.spades, 3)
    sm.set(Suit.clubs, 1)
    sm.set(Suit.hearts, 2)
    sm.set(Suit.clubs, 10)
    var out: List<string> = []
    for k: Suit in sm.keys() {
        match sm.get(k) {
            some(v) => { out.push("{k}={v}") }
            none => {}
        }
    }
    io.println("sortedmap: {out.join(",")}")

    // PriorityQueue keyed by an enum(u8) priority.
    var pq: collections.PriorityQueue<Rank, string> =
        new collections.PriorityQueue<Rank, string>()
    pq.push(Rank.gold, "G")
    pq.push(Rank.bronze, "B")
    pq.push(Rank.silver, "S")
    pq.push(Rank.bronze, "B2")
    var popped: List<string> = []
    for pq.len() > 0 {
        match pq.pop() {
            some(v) => { popped.push(v) }
            none => {}
        }
    }
    io.println("pq: {popped.join(",")}")
}

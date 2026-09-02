// A binary min-heap under two loads: a bulk fill drained in full, and a
// bounded scheduler that pops the due entry whenever more than 1024 are live.
// Priorities collide, so the FIFO tie-break decides the drain order and the
// checksum is order-sensitive.
import std.io
import std.os
import std.collections

fn main() {
    let args: List<string> = os.args()
    let n: int = args.get(0).or("").to_int().or(1_000_000)
    let seed: int = args.get(1).or("").to_int().or(1)
    var checksum: int = 0
    var x: int = 1 + (seed % 2147483646)
    // 1. Fill with n random priorities, then drain in full.
    var q: collections.PriorityQueue<int, int> = new()
    var i: int = 0
    for i < n {
        x = (x * 48271) % 2147483647
        q.push(x % 1000000, i)
        i += 1
    }
    for {
        match q.pop() {
            some(v) => { checksum = (checksum * 31 + v) % 1000000007 }
            none => { break }
        }
    }
    // 2. Scheduler: push each tick, pop the due entry while more than 1024
    //    remain live, so the heap stays small and every op sifts a full depth.
    var sched: collections.PriorityQueue<int, int> = new()
    i = 0
    for i < n {
        x = (x * 48271) % 2147483647
        sched.push(x % 1000000, i)
        if sched.len() > 1024 {
            match sched.pop() {
                some(v) => { checksum = (checksum + v) % 1000000007 }
                none => {}
            }
        }
        i += 1
    }
    io.println("priority_queue {checksum} {sched.len()}")
}

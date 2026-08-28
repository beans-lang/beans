// Deque<int> against std::deque: a FIFO drain, a sliding window of 1024,
// alternating pushes and pops at both ends, then random indexed reads. Every
// phase crosses many 512-slot block boundaries and drives both crossovers.
import std.io
import std.os
import std.collections

fn main() {
    let args: List<string> = os.args()
    let n: int = args.get(0).or("").to_int().or(2_000_000)
    var checksum: int = 0

    // 1. FIFO stream: push_back n, then pop_front n. Draining a full back side
    //    from the front is the pure crossover_to_front pattern.
    var fifo: collections.Deque<int> = new()
    var i: int = 0
    for i < n {
        fifo.push_back(i)
        i += 1
    }
    for {
        match fifo.pop_front() {
            some(v) => { checksum = (checksum * 31 + v) % 1000000007 }
            none => { break }
        }
    }

    // 2. Sliding window of 1024: push_back, and pop_front once past the width.
    var window: collections.Deque<int> = new()
    i = 0
    for i < n {
        window.push_back(i)
        if window.len() > 1024 {
            match window.pop_front() {
                some(v) => { checksum = (checksum + v) % 1000000007 }
                none => {}
            }
        }
        i += 1
    }

    // 3. Both ends: alternate the pushing end, then alternate the popping end.
    var both: collections.Deque<int> = new()
    i = 0
    for i < n {
        if i % 2 == 0 { both.push_front(i) } else { both.push_back(i) }
        i += 1
    }
    i = 0
    for i < n {
        let got: Option<int> = if i % 3 == 0 { both.pop_front() } else { both.pop_back() }
        checksum = (checksum * 7 + got.or(0)) % 1000000007
        i += 1
    }

    // 4. Random access over the filled deque.
    var ra: collections.Deque<int> = new()
    i = 0
    for i < n {
        ra.push_back(i)
        i += 1
    }
    var x: int = 1
    i = 0
    for i < n {
        x = (x * 48271) % 2147483647
        checksum = (checksum + ra.get(x % n).or(0)) % 1000000007
        i += 1
    }

    io.println("deque {checksum}")
}

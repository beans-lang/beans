// Deque<int> against std::deque: a FIFO drain, a sliding window of 1024,
// alternating pushes and pops at both ends, then random indexed reads. Every
// phase crosses many 512-slot block boundaries and drives both crossovers.
//
// The checksum is a position-weighted product folded into a wrapping sum:
// `checksum += v * weight`, with `weight` stepped by a large odd stride. The
// accumulator itself is one add, and both the multiply and the weight step
// are off that dependency chain, so the checksum adds a single cycle of
// latency per value in either language. What the row reports is the deque.
//
// The previous `(checksum * 31 + v) % 1000000007` was a seven-cycle serial
// chain: it hid under Beans' slower loop and stood fully exposed under C++'s
// faster one, which put a floor of about 0.83x under the row that no deque
// implementation, however slow, could sink below. A plain xor against the
// weight is cheaper still but too weak to be a checksum — with values that
// differ in one bit the xor difference stays in that bit, and a phase-3
// mutation that pops from the wrong end (every value off by one) came back
// with a byte-identical answer. The multiply spreads a one-bit difference
// across the whole word.
//
// For the same reason the random-access phase generates its index with a
// wrapping LCG and a multiply-shift instead of `(x * 48271) % 2147483647`
// followed by `% n`: two divisions per read cost more than the read.
import std.io
import std.os
import std.collections

fn main() {
    let args: List<string> = os.args()
    let n: int = args.get(0).or("").to_int().or(2_000_000)
    var checksum: int = 0
    // The weight, stepped by a large odd stride so that two values swapped
    // between neighbouring positions move the sum by a full-width amount and
    // not by one. It runs across every phase, so the checksum answers for the
    // order of the whole trace and not just the order inside one loop.
    var weight: int = 1

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
            some(v) => {
                checksum = checksum + v * weight
                weight += 2654435761
            }
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
                some(v) => {
                    checksum = checksum + v * weight
                    weight += 2654435761
                }
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
        checksum = checksum + got.or(0) * weight
        weight += 2654435761
        i += 1
    }

    // 4. Random access over the filled deque. `x` is a full-width wrapping LCG
    //    and the index is a multiply-shift of its high bits, so the address
    //    stream costs a multiply and an add rather than two divisions.
    var ra: collections.Deque<int> = new()
    i = 0
    for i < n {
        ra.push_back(i)
        i += 1
    }
    var x: int = 1
    i = 0
    for i < n {
        x = x * 6364136223846793005 + 1442695040888963407
        let idx: int = (((x >> 33) & 2147483647) * n) >> 31
        checksum = checksum + ra.get(idx).or(0) * weight
        weight += 2654435761
        i += 1
    }

    io.println("deque {checksum}")
}

// Append and drain, on their own. Every other sequence workload here buries
// them: `sequences` is dominated by its sort and `sequence_churn` by the
// O(n) remove, so a list that reloaded its header from the heap on every
// push went unmeasured (beans #77). Each round builds a list from empty, so
// the growth path is walked ~16 times per round, then drains it with a
// reduction body — the shape whose per-operation change-count store used to
// stop the vectorizer.
import std.io
import std.os

fn main() {
    let args: List<string> = os.args()
    let n: int = args.get(0).or("").to_int().or(40_000_000)
    let seed: int = args.get(1).or("").to_int().or(1)
    let chunk: int = 200_000
    var rounds: int = n / chunk
    if rounds < 1 { rounds = 1 }
    var checksum: int = 0
    var round: int = 0
    for round < rounds {
        var xs: List<int> = []
        var i: int = 0
        for i < chunk {
            xs.push(i + seed)
            i += 1
        }
        checksum += xs.len() + xs[chunk / 2] + round
        var drained: int = 0
        for xs.len() > 0 {
            match xs.pop() {
                some(v) => { drained = drained ^ v }
                none => { break }
            }
        }
        checksum += drained % 1_000_003
        round += 1
    }
    io.println("list_growth {checksum} {rounds} {chunk}")
}

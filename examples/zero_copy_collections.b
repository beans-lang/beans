// Normal collection syntax gets the fast path. No view type or new grammar is
// needed. The compiler borrows each key and value when neither binding escapes
// and the collection cannot change during the loop.
import std.io

class Score {
    points: int
    fn init(points: int) { self.points = points }
}

fn main() {
    var scores: Map<string, Score> = {
        "red": new Score(4),
        "blue": new Score(7),
        "green": new Score(9),
    }

    var total: int = 0
    for name: string, score: Score in scores {
        total += name.len() + score.points
    }
    io.println("{scores.len()} scores, total {total}")

    // This remains an independent owned List. It is allocated at its final
    // size once because it is stored and can outlive the Map iteration.
    let names: List<string> = scores.keys()
    io.println(names.len())

    var numbers: List<int> = [10, 20, 30, 40]
    var middle: int = 0
    // This temporary slice has one read-only consumer, so native code checks
    // the bounds once and walks numbers[1..3] directly. Storing the result in
    // a List would keep the normal independent snapshot behavior.
    for number: int in numbers.slice(1, 3) { middle += number }
    io.println("middle {middle}")
}

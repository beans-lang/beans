// A Deque is a queue you can push and pop at either end in constant time.
// `List` is the right choice when you only ever work at the back; reach for a
// Deque when the front is a working end too — a work queue, a sliding window,
// an undo/redo pair, a breadth-first walk.
//
// The last part of this file is about teardown, which is the part that is
// easy to get wrong: while a Deque is dropping what it holds, the elements'
// own `deinit` bodies can look back at the container. What they see there is
// a rule, not an accident — the storage is set aside and the empty deque
// published *before* the first element is released, so a `deinit` that reads
// it sees an empty container rather than one still claiming to hold what is
// being destroyed.
import std.io
import std.collections

// A breadth-first walk is the classic reason to want both ends: children go
// on the back, the next node comes off the front.
fn level_order(rows: List<List<int>>) -> List<int> {
    var pending: collections.Deque<int> = new collections.Deque<int>()
    pending.push_back(0)
    var visited: List<int> = []
    for !pending.is_empty() {
        match pending.pop_front() {
            some(node) => {
                visited.push(node)
                if node < rows.len() {
                    for child: int in rows[node] {
                        pending.push_back(child)
                    }
                }
            }
            none => {}
        }
    }
    return move visited
}

// A window that keeps the last three readings and drops the oldest.
fn last_three(readings: List<int>) -> List<int> {
    var window: collections.Deque<int> = new collections.Deque<int>()
    for reading: int in readings {
        window.push_back(reading)
        if window.len() > 3 {
            window.pop_front()
        }
    }
    return window.to_list()
}

class Job {
    pub name: string
    priv holder: Option<collections.Deque<Job>>

    fn init(name: string, holder: Option<collections.Deque<Job>>) {
        self.name = name
        self.holder = holder
    }

    // Runs while the deque that owned this job is tearing itself down.
    fn deinit() {
        match self.holder {
            some(deque) => {
                io.println("  dropping {self.name}, queue holds {deque.len()}")
            }
            none => { io.println("  dropping {self.name}") }
        }
    }
}

fn main() {
    io.println("both ends")
    var line: collections.Deque<string> = new collections.Deque<string>()
    line.push_back("second")
    line.push_back("third")
    line.push_front("first")
    io.println("  len {line.len()} first {line.first().or("-")} last {line.last().or("-")}")
    io.println("  front {line.pop_front().or("-")} back {line.pop_back().or("-")}")
    io.println("  left {line.to_list().join(",")}")

    io.println("breadth first")
    let tree: List<List<int>> = [[1, 2], [3, 4], [5], [], [], []]
    io.println("  visited {level_order(tree)}")

    io.println("sliding window")
    io.println("  window {last_three([10, 20, 30, 40, 50])}")

    // The teardown rule. Each job holds the queue it lives in, so its
    // `deinit` reads the container it is being released from.
    io.println("teardown")
    var queue: collections.Deque<Job> = new collections.Deque<Job>()
    queue.push_back(new Job("alpha", some(queue)))
    queue.push_back(new Job("beta", some(queue)))
    queue.push_back(new Job("gamma", some(queue)))
    io.println("  queued {queue.len()}")
    queue.clear()
    io.println("  after clear {queue.len()}")
}

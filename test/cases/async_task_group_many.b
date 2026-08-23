import std.async as aio
import std.io

async fn immediate(value: int) -> int { return value }

async fn main() {
    let group: aio.TaskGroup<int> = new aio.TaskGroup<int>()
    for value: int in 0..10000 { group.start(immediate(value)) }

    var sum: int = 0
    for value: int in 0..10000 {
        match group.try_next() {
            some(found) => { sum += found }
            none => { panic("missing group result") }
        }
    }
    io.println("{sum}")
}

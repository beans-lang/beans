// The panic-storm soak (spec/CONCURRENCY.md, F3): panic containment is a
// per-fiber guarantee, so it has to hold at storm scale, not just for one
// moody child. Waves of TaskGroup fleets where a third of the children
// panic, lone handles joined one by one, a gate storm that wakes sixty
// fibers at once, and senders panicking on a closed channel — every
// failure arrives as a value, the program stands to print "storm stood",
// and both engines print identical bytes, delivery order included.
import std.io

fn stormy(n: int) -> int {
    if n % 3 == 0 { panic("storm child {n}") }
    return n * 2
}

fn fleet_wave(base: int, count: int) -> string {
    let group: TaskGroup<int> = new TaskGroup<int>()
    var index: int = 0
    for index < count {
        group.brew(stormy(base + index))
        index += 1
    }
    var oks: int = 0
    var contained: int = 0
    var sum: int = 0
    for true {
        match group.next() {
            some(outcome) => {
                match outcome {
                    ok(value) => {
                        oks += 1
                        sum += value
                    }
                    err(error) => { contained += 1 }
                }
            }
            none => { break }
        }
    }
    return "{oks} ok, {contained} contained, sum {sum}"
}

fn one_join(n: int) -> int {
    let handle: Brew<int> = brew stormy(n)
    match handle.join() {
        ok(value) => { return value }
        err(error) => { return -1 }
    }
}

fn gate_waiter(gate: Gate, n: int) -> int {
    gate.wait()
    if n % 5 == 0 { panic("woke angry {n}") }
    return 1
}

fn sender(channel: Channel<int>, n: int) -> int {
    channel.send(n) // panics once the channel is closed
    return n
}

fn main() {
    // fleets: eight waves, 120 children each, a third of them panicking
    var wave_index: int = 0
    for wave_index < 8 {
        io.println(
            "wave {wave_index}: {fleet_wave(wave_index * 120, 120)}")
        wave_index += 1
    }

    // lone handles: 150 brews joined one by one, panics arriving as err
    var joined_sum: int = 0
    var joined_contained: int = 0
    var join_index: int = 0
    for join_index < 150 {
        let value: int = one_join(join_index)
        if value < 0 {
            joined_contained += 1
        } else {
            joined_sum += value
        }
        join_index += 1
    }
    io.println(
        "joins: {joined_contained} contained, sum {joined_sum}")

    // a gate storm: sixty parked waiters wake at once, every fifth
    // panics on waking; the first failure is the fleet's answer
    let gate: Gate = new Gate()
    let woken: TaskGroup<int> = new TaskGroup<int>()
    var waiter_index: int = 0
    for waiter_index < 60 {
        woken.brew(gate_waiter(gate, waiter_index))
        waiter_index += 1
    }
    gate.open()
    match woken.wait_all() {
        ok(values) => { io.println("gate storm: all calm") }
        err(error) => {
            io.println("gate storm: {error.kind} contained")
        }
    }

    // closed-channel storm: capacity four, twenty senders — four sends
    // land in the buffer and finish, sixteen park in the send line. The
    // first next() parks this fiber, which is what lets the senders run;
    // after the four landings the close wakes the parked sixteen into
    // the send-on-closed panic, contained like any other.
    let channel: Channel<int> = new Channel<int>(4)
    let senders: TaskGroup<int> = new TaskGroup<int>()
    var sender_index: int = 0
    for sender_index < 20 {
        senders.brew(sender(channel, sender_index))
        sender_index += 1
    }
    var landed: int = 0
    var refused: int = 0
    for landed < 4 {
        match senders.next() {
            some(outcome) => {
                match outcome {
                    ok(value) => { landed += 1 }
                    err(error) => { refused += 1 }
                }
            }
            none => { break }
        }
    }
    channel.close()
    for true {
        match senders.next() {
            some(outcome) => {
                match outcome {
                    ok(value) => { landed += 1 }
                    err(error) => { refused += 1 }
                }
            }
            none => { break }
        }
    }
    io.println("channel storm: {landed} landed, {refused} contained")

    io.println("storm stood")
}

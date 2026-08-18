// A struct that reaches itself through its own fields has no finite layout,
// and that error is reported on its own terms. Checking carries on past it, so
// the cyclic type is still around to be asked other questions — including
// whether it is move-only. This case pins that the answer comes back instead
// of walking the cycle until the stack runs out.

struct Loop {
    next: Loop
}

struct Ping {
    pong: Pong
}

struct Pong {
    ping: Ping
}

fn main() {
    var loops: List<Loop> = []
    let first: Option<Loop> = loops.get(0)
    var pings: List<Ping> = []
    let second: Option<Ping> = pings.get(0)
}

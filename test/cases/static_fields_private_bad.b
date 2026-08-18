class State {
    priv static value: int = 1
}

class Peer {
    static fn read() -> int {
        return State.value
    }
}

fn main() {}

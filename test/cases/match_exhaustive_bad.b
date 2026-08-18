enum State {
    ready
    busy
    done
}

fn enum_missing(value: State) -> int {
    return match value {
        ready => 1,
        busy => 2,
    }
}

fn bool_missing(value: bool) -> int {
    return match value {
        true => 1,
    }
}

fn scalar_missing(value: int) -> int {
    return match value {
        0 => 1,
    }
}

fn main() {}

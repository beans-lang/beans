enum State {
    ready
}

fn main() {
    let state: State = State.ready
    match state {
        missing => 0,
        _ => 1,
    }
    match 1 {
        ready => 0,
        _ => 1,
    }
    match true {
        1 => 0,
        true => 1,
        false => 2,
    }
    match 1 {
        1.5 => 0,
        _ => 1,
    }
}

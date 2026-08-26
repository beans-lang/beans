// Equality for the composites that were getting it wrong, each a different
// fault in the same corner of the emitter:
//
//   * a struct holding a payload-carrying enum compared by address, so equal
//     values were called different. A bare `a == b` was always right, because
//     that goes through the structural thunk; only an enum in a field took
//     the identity path.
//   * a struct holding `Option<S>` where S itself holds Options failed to
//     build at all — "PHI node entries do not match predecessors". The
//     payload comparison opens blocks of its own, so the block that branch
//     started in was not the block it ended in.
package main

import std.io

pub struct Pt {
    pub x: f32 = 0.0
}

pub enum Delta {
    pixels(v: Pt)
    lines(v: Pt)
}

pub enum Count {
    one(v: int)
    two(v: int)
}

pub struct WithDelta {
    pub delta: Delta = Delta.lines(Pt { x: 0.0 })
    pub label: string = ""
}

pub struct WithCount {
    pub count: Count = Count.one(0)
}

pub struct Titlebar {
    pub transparent: bool = false
    pub light_position: Option<f32> = none
    pub label: Option<string> = none
}

pub struct WindowOptions {
    pub titlebar: Option<Titlebar> = none
    pub title: Option<string> = none
    pub focus: bool = true
}

fn main() {
    // the bare enum was always right; the wrapped one was not
    let bare_left: Delta = Delta.lines(Pt { x: 1.0 })
    let bare_right: Delta = Delta.lines(Pt { x: 1.0 })
    let other_arm: Delta = Delta.pixels(Pt { x: 1.0 })
    io.println("bare {bare_left == bare_right} {bare_left == other_arm}")

    let wrapped: WithDelta = WithDelta { delta: Delta.lines(Pt { x: 1.0 }) }
    let alike: WithDelta = WithDelta { delta: Delta.lines(Pt { x: 1.0 }) }
    let arm_differs: WithDelta = WithDelta { delta: Delta.pixels(Pt { x: 1.0 }) }
    let payload_differs: WithDelta = WithDelta { delta: Delta.lines(Pt { x: 2.0 }) }
    io.println("wrapped {wrapped == alike} {wrapped == arm_differs} {wrapped == payload_differs}")

    // the payload's own type was never the issue: a bare int failed too
    let counted: WithCount = WithCount { count: Count.one(5) }
    let counted_alike: WithCount = WithCount { count: Count.one(5) }
    let counted_differs: WithCount = WithCount { count: Count.one(6) }
    io.println("count {counted == counted_alike} {counted == counted_differs}")

    // Option inside Option inside a record: this shape would not build
    let opts: WindowOptions = WindowOptions {
        titlebar: some(Titlebar { light_position: some(1.0) }),
    }
    let opts_alike: WindowOptions = WindowOptions {
        titlebar: some(Titlebar { light_position: some(1.0) }),
    }
    let no_titlebar: WindowOptions = WindowOptions { titlebar: none }
    let inner_differs: WindowOptions = WindowOptions {
        titlebar: some(Titlebar { light_position: some(2.0) }),
    }
    io.println("nested {opts == opts_alike} {opts == no_titlebar} {opts == inner_differs}")
}

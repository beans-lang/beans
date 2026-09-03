// Where a value can be *written*, and how to say you do not want one.
//
// A place is storage you can name and assign to. Beans has four roots: a
// local, a parameter you took `inout`, a heap object reached through a
// reference, and a `static`. A struct field is a place at any depth beneath
// any of them, so `a.b.c.d = v` writes through to the storage that holds it
// rather than to a copy that is thrown away.
//
// `_` is the other half: it names nothing. Use it when a value has to be
// produced but you have no use for it. It is not a variable — you cannot read
// it back, and you cannot assign to it.
import std.io

struct Point {
    x: int
    y: int

    // A struct method gets a read-only `self`. `inout fn` is how a method
    // says it writes through the receiver, and the caller then needs a place
    // to call it on rather than a temporary copy.
    inout fn shift(dx: int, dy: int) {
        self.x = self.x + dx
        self.y = self.y + dy
    }
}

struct Panel {
    corner: Point
    label: string
}

struct Frame {
    inner: Panel
    depth: int
}

class Canvas {
    pub frame: Frame

    fn init() {
        self.frame = Frame {
            inner: Panel {
                corner: Point { x: 0, y: 0 },
                label: "start",
            },
            depth: 1,
        }
    }

    // A class is a reference, so an ordinary method writes through it. (A
    // *struct* method is the one that has to say `inout fn`: without it
    // `self` is borrowed and its fields cannot be reassigned.)
    fn slide(dx: int, dy: int) {
        self.frame.inner.corner.x = self.frame.inner.corner.x + dx
        self.frame.inner.corner.y = self.frame.inner.corner.y + dy
    }
}

class Settings {
    // a static is a place root of its own: it has no owner, and it lives for
    // the whole program
    pub static origin: Point = Point { x: 0, y: 0 }
    pub static tag: string = "unset"
}

// An `inout` parameter is a place the caller lends you.
fn deepen(inout frame: Frame, by: int) {
    frame.depth = frame.depth + by
    frame.inner.label = "depth {frame.depth}"
}

fn next_id(inout counter: int) -> int {
    counter = counter + 1
    return counter
}

fn main() {
    // 1. a local, written at depth
    var frame: Frame = Frame {
        inner: Panel {
            corner: Point { x: 1, y: 2 },
            label: "local",
        },
        depth: 0,
    }
    frame.inner.corner.x = 10
    frame.inner.label = "moved"
    io.println("local  {frame.inner.corner.x},{frame.inner.corner.y} {frame.inner.label}")

    // an `inout fn` writes through the receiver, and wants a mutable local
    // to call it on
    var origin: Point = Point { x: 0, y: 0 }
    origin.shift(3, 4)
    io.println("method {origin.x},{origin.y}")

    // 2. an inout parameter, written at depth by the callee
    deepen(inout frame, 3)
    io.println("inout  depth {frame.depth} label {frame.inner.label}")

    // 3. a heap object, written through the reference
    let canvas: Canvas = new Canvas()
    canvas.frame.inner.corner.x = 5
    canvas.frame.inner.label = "canvas"
    canvas.slide(2, 7)
    io.println("object {canvas.frame.inner.corner.x},{canvas.frame.inner.corner.y} {canvas.frame.inner.label}")

    // 4. a static, written at depth like any other storage
    Settings.origin.x = 100
    Settings.origin.y = 200
    Settings.tag = "ready"
    io.println("static {Settings.origin.x},{Settings.origin.y} {Settings.tag}")

    // `_` discards. The call still happens; the value is simply dropped.
    var counter: int = 0
    for turn: int in 0..3 {
        let _: int = next_id(inout counter)
    }
    io.println("discard counter {counter}")

    // and it discards a binding in a pattern the same way, so an arm can
    // say it does not care about the payload it matched
    let readings: List<Option<int>> = [some(4), none, some(9)]
    var kept: int = 0
    for reading: Option<int> in readings {
        match reading {
            some(_) => { kept = kept + 1 }
            none => {}
        }
    }
    io.println("discard kept {kept}")
}

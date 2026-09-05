// #120 through reflection: Initializer.call() is construction, so an
// initializer that panics under it leaves the same half-built object and the
// same rule applies -- no deinit body, and no handle to a thing that was never
// built. The tree interpreter used to register the object in its reflect value
// registry anyway; nothing then released it until the exit-time cycle sweep,
// which handed it to its own deinit long after the unwind that made it, so a
// contained panic ended the process with an "has no initialized field" report
// at exit. Native leaves that object unreleased instead. Both now answer the
// same thing and exit 0.
//
// The second half is the control: a reflective construction that FINISHES
// still hands back a usable value. It uses a class with no deinit on purpose
// -- a reflectively constructed object that carries one is not released at
// all in a native build today (the Result<Value, E> the call answers is a
// separate, pre-existing leak), so its deinit is not a thing this golden can
// pin on both engines. What it does pin is that the failed construction above
// changed nothing for a construction that works.
import std.io
import std.reflect

class Made {
    a: int
    b: string
    pub fn init(x: int) {
        self.a = x
        if x > 0 { panic("reflect boom") }
        self.b = "ok"
    }
    fn deinit() { io.println("  made deinit a={self.a} b={self.b}") }
}

class Fine {
    a: int
    pub fn init(x: int) {
        self.a = x
        if x > 100 { panic("fine boom") }
    }
}

fn build(x: int) -> int {
    match type_of(Made).initializer() {
        some(constructor) => {
            match constructor.call([reflect.value(x)]) {
                ok(value) => {
                    match value as? Made {
                        some(made) => {
                            io.println("  built a={made.a} b={made.b}")
                        }
                        none => { io.println("  not a Made") }
                    }
                }
                err(problem) => { io.println("  reflect error") }
            }
        }
        none => { io.println("  no initializer") }
    }
    return x
}

fn build_fine(x: int) -> int {
    match type_of(Fine).initializer() {
        some(constructor) => {
            match constructor.call([reflect.value(x)]) {
                ok(value) => {
                    match value as? Fine {
                        some(made) => { io.println("  built fine a={made.a}") }
                        none => { io.println("  not a Fine") }
                    }
                }
                err(problem) => { io.println("  reflect error") }
            }
        }
        none => { io.println("  no initializer") }
    }
    return x
}

fn run_shape(which: int, x: int) -> int {
    if which == 1 { return build(x) }
    return build_fine(x)
}

fn contain(which: int, x: int, name: string) {
    io.println("-- {name} --")
    let h: Brew<int> = brew run_shape(which, x)
    match h.join() {
        ok(v) => { io.println("  ok {v}") }
        err(e) => { io.println("  err {e.msg}") }
    }
    io.println("  after")
}

fn main() {
    contain(1, 1, "reflective init panics")
    contain(2, 7, "reflective init finishes")
    io.println("end")
}

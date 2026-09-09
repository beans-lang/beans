// `unit` is what a function that returns nothing answers with, not a value.
// Every shape here asked for a value of it, and every one of them used to pass
// `check`, run under the tree interpreter, and fail only `beansc build`, in the
// emitter's own words — "LLVM emitter does not support brewing 'unit' yet",
// "does not support local type 'List<unit>' yet" (issue #154).
//
// One shape proves nothing here: the type is written in some of these and
// worked out by inference in the others, and the inferred ones are the ones a
// check on the spelling would miss.
import std.io

fn nothing() {
    io.println("nothing")
}

fn wrap<T>(value: T) -> Result<T> {
    return ok(value)
}

fn hold<T>(value: T) -> List<T> {
    return [value]
}

// T is bound through a function RESULT, which is the one slot `unit` belongs
// in, so nothing about this call is written and nothing about the argument is
// wrong — only the `Result<unit>` inference works out for the answer.
fn produced<T>(make: fn() -> T) -> Result<T> {
    return ok(make())
}

class Worker {
    pub n: int = 0
    pub fn run(step: int) {
        io.println("run {step}")
    }
}

// --- written: `Result<unit>` spelled out, in every declared position -------

fn declared_result() -> Result<unit> {
    return ok(nothing())
}

struct Carrier {
    pub answer: Result<unit>
}

interface Runner {
    fn go() -> Result<unit>
}

fn declared_parameter(answer: Result<unit>) -> int {
    return 1
}

// --- written: bare `unit` where a value has to live -----------------------

fn declared_unit_parameter(value: unit) -> int {
    return 2
}

struct Slot {
    pub value: unit
}

enum Step {
    idle
    ran(value: unit)
}

fn declared_unit_local() {
    let value: unit = nothing()
    io.println("kept a nothing")
}

// --- written: a container asked to hold one ------------------------------

fn declared_containers() {
    let items: List<unit> = []
    let table: Map<string, unit> = {}
    let boxed: Box<unit> = new Box<unit>(nothing())
    let shared: Shared<unit> = new Shared<unit>(nothing())
    let channel: Channel<unit> = new Channel<unit>(1)
    io.println("{items.len()} {table.len()}")
}

// --- inferred: nobody wrote the type -------------------------------------

fn joined_brew() {
    let handle: Brew<unit> = brew nothing()
    match handle.join() {
        ok(value) => { io.println("joined") }
        err(problem) => { io.println("{problem.kind}") }
    }
}

fn joined_method_brew() {
    let worker: Worker = new Worker()
    let handle: Brew<unit> = brew worker.run(3)
    match handle.join() {
        ok(value) => { io.println("joined") }
        err(problem) => { io.println("{problem.kind}") }
    }
}

fn delivered_group() {
    let fleet: TaskGroup<unit> = new TaskGroup<unit>()
    fleet.brew(nothing())
    match fleet.next() {
        some(outcome) => { io.println("delivered") }
        none => { io.println("empty") }
    }
}

fn awaited_group() {
    let fleet: TaskGroup<unit> = new TaskGroup<unit>()
    fleet.brew(nothing())
    match fleet.wait_all() {
        ok(values) => { io.println("{values.len()}") }
        err(problem) => { io.println("{problem.kind}") }
    }
}

fn generic_result() {
    match wrap(nothing()) {
        ok(value) => { io.println("wrapped") }
        err(problem) => { io.println("{problem.kind}") }
    }
}

fn inferred_result() {
    match produced(fn() { }) {
        ok(value) => { io.println("produced") }
        err(problem) => { io.println("{problem.kind}") }
    }
}

fn generic_element() {
    io.println("{hold(nothing()).len()}")
}

fn optional_nothing() {
    io.println("{some(nothing()).is_some()}")
}

fn main() {
    declared_unit_local()
    declared_containers()
    joined_brew()
    joined_method_brew()
    delivered_group()
    awaited_group()
    generic_result()
    inferred_result()
    generic_element()
    optional_nothing()
    io.println("{declared_result().is_ok()}")
}

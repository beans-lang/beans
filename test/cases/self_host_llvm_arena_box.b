// Arena<T> and Box<T> slot forms: the runtime owns what it
// stores (puts and sets retain non-consumed operands), reads
// hand back counts of their own, Arena.get answers an Option
// whose miss payload is the zero the runtime returned, and
// clear releases arena slots. Tracer deinits pin every
// ownership handoff.
import std.io

class Tracer {
    name: string

    fn init(name: string) {
        self.name = name
    }

    fn deinit() {
        io.println("drop {self.name}")
    }
}

fn main() {
    let numbers: Arena<int> = new Arena<int>(4)
    let first: int = numbers.add(10)
    let second: int = numbers.add(20)
    io.println("len {numbers.len()}")
    io.println("{numbers.get(first).or(-1)} {numbers.get(second).or(-1)}")
    io.println("{numbers.get(99).or(-1)}")
    numbers.clear()
    io.println("cleared {numbers.len()}")

    let names: Arena<string> = new Arena<string>(2)
    let n0: int = names.add("alpha")
    io.println("{names.get(n0).or("missing")}")
    io.println("{names.get(5).or("missing")}")

    let cell: Box<int> = new Box<int>(7)
    io.println("{cell.get()}")
    cell.set(9)
    io.println("{cell.get()}")

    let label: Box<string> = new Box<string>("start")
    io.println("{label.get()}")
    label.set("end")
    io.println("{label.get()}")

    let owned: Arena<Tracer> = new Arena<Tracer>(2)
    let t0: int = owned.add(new Tracer("kept"))
    io.println("put done")
    match owned.get(t0) {
        some(found) => { io.println("found {found.name}") }
        none => { io.println("missing") }
    }
    owned.clear()
    io.println("after clear")

    let boxed: Box<Tracer> = new Box<Tracer>(new Tracer("first"))
    boxed.set(new Tracer("second"))
    io.println("swapped")
}

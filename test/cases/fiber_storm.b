// Fiber-storm gate (driven by test/fiber_stacks.sh).
//
// A worker pools a bounded number of finished fibers for stack reuse and
// releases the rest, so a burst of many fibers gives its stacks back when the
// burst is over. This spawns a chain of `count` fibers — each one parks the
// next and then waits, so all `count` are alive at once — holds them while the
// shell samples the resident high-water, wakes them with one gate open, joins
// the whole chain, and holds again for the shell to see the set fall back.
//
// A Brew handle cannot ride inside a container, so the storm is held by the
// fiber scheduler through the chain of locals, not by a Beans list. It runs
// twice: the second burst must reuse the warm pool and so must not be slower
// than the first by more than the shared box's noise.
import std.io
import std.time as time

fn fan(gate: Gate, n: int) -> int {
    if n <= 0 { gate.wait(); return 0 }
    let child: Brew<int> = brew fan(gate, n - 1)
    gate.wait()
    match child.join() { ok(v) => { return v + 1 } err(_) => { return 0 } }
}

fn wait_stdin() { match io.read_line() { some(_) => {} none => {} } }

fn run_storm(tag: string, n: int) -> int {
    let gate: Gate = new Gate()
    let top: Brew<int> = brew fan(gate, n)
    time.sleep_millis(700)                 // let the whole chain spawn and park
    io.eprintln("phase parked-{tag}")
    wait_stdin()
    gate.open()
    let depth: int = match top.join() { ok(v) => v, err(_) => -1 }
    io.eprintln("phase joined-{tag} {depth}")
    wait_stdin()
    return depth
}

fn main() {
    io.eprintln("phase baseline")
    wait_stdin()
    let a: int = run_storm("1", 10000)
    let b: int = run_storm("2", 10000)
    io.eprintln("phase done {a} {b}")
}

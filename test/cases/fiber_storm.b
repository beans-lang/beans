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

// `built` is opened by the last link, which only runs once every fiber above
// it has already executed its own `brew` — so when it opens, all `count`
// fibers exist and have run, and every one of them has touched its stack. The
// driver samples the resident set on that signal instead of on a sleep, which
// is what lets it assert a floor derived from the fiber count: a sleep that
// the box outruns leaves part of the chain unbuilt and the high-water short,
// and the gate would be measuring how fast the machine is.
fn fan(gate: Gate, built: Gate, n: int) -> int {
    if n <= 0 { built.open(); gate.wait(); return 0 }
    let child: Brew<int> = brew fan(gate, built, n - 1)
    gate.wait()
    match child.join() { ok(v) => { return v + 1 } err(_) => { return 0 } }
}

fn wait_stdin() { match io.read_line() { some(_) => {} none => {} } }

fn run_storm(tag: string, n: int) -> int {
    // Both gates are fresh per burst: a Gate is sticky, so a reused one would
    // report the previous chain.
    let gate: Gate = new Gate()
    let built: Gate = new Gate()
    let top: Brew<int> = brew fan(gate, built, n)
    built.wait()                           // the whole chain is up and parked
    io.eprintln("phase parked-{tag}")
    wait_stdin()
    gate.open()
    let depth: int = match top.join() { ok(v) => v, err(_) => -1 }
    io.eprintln("phase joined-{tag} {depth}")
    wait_stdin()
    return depth
}

fn main() {
    // One place decides how many fibers a storm holds, and the driver reads it
    // from here rather than repeating it: every expectation the driver asserts
    // -- the depth the chain must reach, and the resident stacks that many
    // parked fibers must cost -- is derived from this number, so changing it
    // needs no matching edit in the shell.
    let storm: int = 10000
    io.eprintln("fibers {storm}")
    io.eprintln("phase baseline")
    wait_stdin()
    let a: int = run_storm("1", storm)
    let b: int = run_storm("2", storm)
    io.eprintln("phase done {a} {b}")
}

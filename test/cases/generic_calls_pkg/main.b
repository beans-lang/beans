// A package's function used as a value — the wall that forced every
// example to wrap library functions in lambdas. Direct, aliased, stored,
// passed, and mixed with explicit type arguments on the package call form.
package main
import std.io
import app.tools
import app.tools as t

pub class Hooks {
    pub sinks: List<fn(string)>
    pub fn init() { self.sinks = [] }
    pub fn use(sink: fn(string)) { self.sinks.push(sink) }
    pub fn emit(line: string) {
        for sink: fn(string) in self.sinks { sink(line) }
    }
}

fn apply(f: fn(string) -> string, value: string) -> string {
    return f(value)
}

fn main() {
    let f: fn(string) -> string = tools.shout
    io.println(f("direct"))
    io.println(apply(t.shout, "aliased"))
    var ops: List<fn(int) -> int> = [tools.twice, t.twice]
    io.println(ops[0](10) + ops[1](11))
    // the espresso README shape: a framework hook taking a library
    // function without a wrapping lambda
    let hooks: Hooks = new Hooks()
    hooks.use(tools.log_line)
    hooks.emit("ready")
    // explicit type arguments on the package-qualified call form
    io.println(tools.pick<string>("chosen"))
    io.println(t.pick<int>(12))
    io.println("done")
}

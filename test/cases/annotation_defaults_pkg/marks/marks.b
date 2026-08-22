// The annotation whose defaults must resolve here, in the declaring
// package's scope — not wherever the annotation is used.
package marks
import std.io

pub enum Level {
    low
    high
}

pub fn plain_name() -> string { return "fallback" }

@target(value: ["type"])
@retention(value: "runtime")
pub annotation mark {
    level: Level = Level.high
    label: string = "unnamed"
}

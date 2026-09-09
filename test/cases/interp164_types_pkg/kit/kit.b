// The package every other file in this module reaches by name. Nothing
// here is unusual: a base class and a subclass, a struct with a layout, a
// module constant, an enum, a class with a static, and functions that take
// and return those types — enough for one type name to be written in every
// position a type can be written in.
package kit

pub const SIZE: int = 3

pub struct Point {
    pub x: int
    pub y: int
}

pub class Widget {
    pub fn init() {}
    pub fn label() -> string { return "widget" }
}

pub class Fancy extends Widget {
    pub fn init() { super.init() }
    pub override fn label() -> string { return "fancy" }
}

pub fn make() -> Widget { return new Widget() }
pub fn fancy() -> Fancy { return new Fancy() }
pub fn takes(f: fn(Widget) -> int, w: Widget) -> int { return f(w) }
pub fn transform(f: fn(Widget) -> string, w: Widget) -> string {
    return f(w)
}
pub fn wrap(f: fn(fn(Widget) -> int) -> int) -> int {
    return f(fn(w: Widget) -> int { return 4 })
}
pub fn count<T>(value: T) -> int { return 2 }

pub enum Tone { quiet, loud }

pub class Shop {
    pub fn init() {}
    pub static fn tally() -> int { return 7 }
}

// One row of the report: what was asked, what the same words answered
// inside a string's `{}` piece, and what they answered one character
// outside it. The verdict is computed here so a regenerated golden still
// carries the claim; the two answers are printed so the golden pins the
// qualified names themselves and not just the word "agree".
pub fn row(label: string, inside: string, outside: string) -> string {
    let verdict: string =
        if inside == outside { "agree" } else { "DIFFER" }
    return "{label}: inside={inside} outside={outside} {verdict}"
}

// The package main selects from: a function, a class with a static, and
// an annotation, plus one private function the _bad twin tries to take.
package tools

pub annotation tagged {
    label: string = ""
}

pub fn shout(message: string) -> string { return "{message}!" }
fn hidden(value: int) -> int { return value }

pub class Greeter {
    pub prefix: string
    pub fn init(prefix: string) { self.prefix = prefix }
    pub fn greet(name: string) -> string { return "{self.prefix} {name}" }
    pub static fn plain() -> Greeter { return new Greeter("plain") }
}

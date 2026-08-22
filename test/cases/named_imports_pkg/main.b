// Selecting from another package of the same module: a function called
// bare, a class built with new and reached statically, and an annotation
// applied by its bare name.
package main
import {println} from std.io
import {shout, Greeter, tagged} from app.tools

@tagged(label: "entry")
pub class App {
    pub fn init() {}
}

fn main() {
    println(shout("named"))
    let g: Greeter = new Greeter("hey")
    println(g.greet("you"))
    let p: Greeter = Greeter.plain()
    println(p.greet("static"))
}

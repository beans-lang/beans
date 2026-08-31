// A base class hands its slot to a subclass, so its declared type is not the
// only shape a value can carry — refused rather than rendered two ways.
import std.io
class Animal { name: string; fn init(name: string) { self.name = name } }
class Dog extends Animal { fn init(name: string) { super.init(name) } }
fn main() {
    let a: Animal = new Animal("x")
    io.println("{a}")
}

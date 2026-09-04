// #94: the shapes the construction proof must accept, and both backends must
// agree on. Branches and an exhaustive match that assign a field on every arm,
// a method call and interpolation once every field is assigned, and a base
// initializer that calls a method the subclass overrides — safe because the
// subclass assigns its own field before super.init, which is the whole reason
// the order is fixed.
import std.io

class Branchy {
    a: int
    b: int
    fn init(x: int) {
        if x > 0 {
            self.a = 1
        } else {
            self.a = 2
        }
        match x {
            0 => { self.b = 10 }
            _ => { self.b = 20 }
        }
    }
    fn show() -> string { return "a={self.a} b={self.b}" }
}

class Animal {
    name: string
    fn init(name: string) {
        self.name = name
        io.println("animal init hears {self.speak()}")
    }
    fn speak() -> string { return self.name }
}

class Dog extends Animal {
    breed: string
    fn init(breed: string, name: string) {
        self.breed = breed
        super.init(name)
        io.println("dog {self.name} the {self.breed}")
    }
    override fn speak() -> string { return "{self.name}#{self.breed}" }
}

fn main() {
    let p: Branchy = new Branchy(1)
    io.println("branchy1 {p.show()}")
    let q: Branchy = new Branchy(0)
    io.println("branchy0 {q.show()}")
    let d: Dog = new Dog("corgi", "rex")
    io.println("done {d.speak()}")
}

import std.io

class Leaf {
    name: string

    fn init(name: string) {
        self.name = name
    }

    fn deinit() {
        io.println("leaf {self.name} down")
    }
}

class Base {
    leaf: Leaf = new Leaf("base-field")

    fn deinit() {
        io.println("base down")
    }
}

class Child extends Base {
    fn deinit() {
        io.println("child down")
        if true {
            return
        }
    }
}

class OwnedBox<T> {
    item: T

    fn init(item: T) {
        self.item = item
    }

    fn deinit() {
        io.println("box down")
    }
}

class Animal {
    name: string

    fn init(name: string) {
        self.name = name
    }

    fn deinit() {
        io.println("animal down")
    }
}

class Dog extends Animal {
    breed: string

    fn init(breed: string, name: string) {
        self.breed = breed
        super.init(name)
    }

    fn deinit() {
        io.println("dog down")
    }
}

class Pup extends Dog {
    treats: int = 3
}

fn inherited_default() {
    let child: Child = new Child()
    io.println("child alive")
}

fn generic_deinit() {
    let box: OwnedBox<Leaf> =
        new OwnedBox(new Leaf("boxed"))
    io.println("box alive")
}

fn inherited_init() {
    let pup: Pup = new Pup("lab", "sam")
    io.println("{pup.name} {pup.breed} {pup.treats}")
}

fn main() {
    inherited_default()
    generic_deinit()
    inherited_init()
}

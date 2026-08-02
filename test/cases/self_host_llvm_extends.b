import std.io

class Animal {
    name: string
    legs: int

    fn init(move name: string, legs: int) {
        self.name = move name
        self.legs = legs
    }

    fn describe() -> string {
        return "{self.name} on {self.legs} legs"
    }
}

class Dog extends Animal {
    tricks: int

    fn init(move name: string) {
        self.tricks = 0
        super.init(move name, 4)
    }

    fn deinit() {
        io.println("kennel closed for {self.name}")
    }

    fn learn() {
        self.tricks += 1
    }
}

class Bird extends Animal {
    fn init(move name: string) {
        super.init(move name, 2)
    }
}

fn main() {
    var pet: Dog = new Dog("rex")
    pet.learn()
    pet.learn()
    io.println("{pet.describe()} with {pet.tricks} tricks")
    var alias: Animal = pet
    io.println(alias.describe())
    var shelter: List<Animal> = []
    shelter.push(new Bird("kiwi"))
    shelter.push(new Dog("spot"))
    shelter.push(new Animal("slug", 0))
    for resident: Animal in shelter {
        io.println("here lives {resident.describe()}")
    }
    io.println("closing the shelter")
}

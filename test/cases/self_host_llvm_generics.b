// Generic monomorphization through the self-host LLVM emitter: a
// free function instantiates once per concrete signature, a generic
// class mints a class id and layout per instantiation, and methods
// register under the rendered instance name.
import std.io

fn pick<T>(flag: bool, left: T, right: T) -> T {
    if flag {
        return left
    }
    return right
}

class Crate<T> {
    value: T

    fn init(value: T) {
        self.value = value
    }

    fn get() -> T {
        return self.value
    }

    fn put(value: T) {
        self.value = value
    }
}

fn main() {
    io.println("{pick(true, 1, 2)}")
    io.println(pick(false, "lo", "hi"))
    let numbers: Crate<int> = new Crate(41)
    numbers.put(numbers.get() + 1)
    io.println("{numbers.get()}")
    let words: Crate<string> = new Crate("beans")
    io.println(words.get())
}

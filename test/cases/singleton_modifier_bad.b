singleton class WithArgument {
    fn init(value: int) {}
}

singleton class WithDeinit {
    fn deinit() {}
}

singleton class Generic<T> {}

singleton abstract class Mixed {}

class Child extends WithArgument {}

fn main() {}

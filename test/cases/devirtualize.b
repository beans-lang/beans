import std.io

interface Metric {
    fn value(input: int) -> int
}

class Add implements Metric {
    amount: int

    fn init(amount: int) {
        self.amount = amount
    }

    fn value(input: int) -> int {
        return self.amount + input
    }
}

class Multiply implements Metric {
    amount: int

    fn init(amount: int) {
        self.amount = amount
    }

    fn value(input: int) -> int {
        return self.amount * input
    }
}

interface Named {
    fn name() -> string
}

class Name implements Named {
    text: string

    fn init(text: string) {
        self.text = text
    }

    fn name() -> string {
        return self.text
    }
}

interface Counter {
    fn add(value: int)
}

class Running implements Counter {
    total: int

    fn init() {
        self.total = 0
    }

    fn add(value: int) {
        self.total += value
    }

    fn get() -> int {
        return self.total
    }
}

fn argument() -> int {
    io.println("argument")
    return 4
}

fn main() {
    let add: Add = new Add(3)
    let first: Metric = add
    var total: int = first.value(argument())

    let multiply: Multiply = new Multiply(5)
    let second: Metric = multiply
    total += second.value(argument())

    io.println(total)

    let named_value: Name = new Name("bean")
    let named: Named = named_value
    io.println(named.name())

    let running: Running = new Running()
    let counter: Counter = running
    counter.add(6)
    io.println(running.get())
}

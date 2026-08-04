// a generic class with a deinit — destruction dispatches through the same
// descriptor slot as a non-generic class, per instantiation. run vs build
// must print the same lines in the same order.
import std.io

class Guard<T> {
    label: string
    value: T

    fn init(label: string, move value: T) {
        self.label = label
        self.value = move value
    }

    pub fn peek() -> string { return self.label }

    fn deinit() {
        io.println("closing {self.label}")
    }
}

unique class Ticket<T> {
    stamp: fn() -> T
    used: bool = false

    pub fn init(stamp: fn() -> T) {
        self.stamp = stamp
    }

    pub fn redeem() -> T {
        self.used = true
        let produce: fn() -> T = self.stamp
        return produce()
    }

    fn deinit() {
        if !self.used { io.println("ticket wasted") }
    }
}

// Tickets come from a factory, the same shape std.async task makers use:
// the closure captures the factory's locals, the caller's frame only holds
// the ticket, so nothing keeps the pair alive in a cycle.
fn numbered_ticket(start: int) -> Ticket<int> {
    var serial: int = start
    return new Ticket<int>(fn() -> int {
        serial += 1
        return serial
    })
}

fn wasted_ticket() -> Ticket<string> {
    return new Ticket<string>(fn() -> string { return "never" })
}

fn main() {
    let words: Guard<string> = new Guard("words", "beans")
    io.println("holding {words.peek()}")
    if true {
        let numbers: Guard<int> = new Guard("numbers", 41)
        io.println("holding {numbers.peek()}")
    }
    let spent: Ticket<int> = numbered_ticket(100)
    io.println("redeemed {spent.redeem()}")
    let wasted: Ticket<string> = wasted_ticket()
    io.println("done")
}

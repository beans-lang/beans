// Files in the same package do not need imports from each other.
package main

import std.io
import shop.money

fn banner(title: string) {
    io.println("== {title} ==")
}

class Cart {
    items: List<money.Money> = []

    fn add(m: money.Money) {
        self.items.push(m)
    }

    fn total() -> money.Money {
        return money.total(self.items)
    }
}

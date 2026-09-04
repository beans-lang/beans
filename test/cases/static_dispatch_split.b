// A `static fn` declares no `self`, so it is not a method any receiver can
// pick: it owns no dispatch slot, no selector index and no descriptor row.
// Before #88 every static got one anyway — a lone static with nothing to
// collide with still put a receiverless function in its class's table — and
// a subclass's static replaced the row its base's instance method had
// filled.
//
// Nothing here is a collision: no static shares a name with an instance
// method its family can reach. What the case pins is that the rows still
// hold exactly the methods that dispatch, and that dispatch through a
// base-typed reference still finds every override.
package main

import std.io

// ---- statics beside instance methods that dispatch ----------------------

class Shape {
    tag: string

    fn init(tag: string) { self.tag = tag }

    fn area() -> int { return 0 }

    fn describe() -> string {
        return "{self.tag}={self.area()}"
    }

    // one static on the base and one on each subclass, all with names no
    // instance method in the family wears
    static fn origin() -> Shape { return new Shape("origin") }
}

class Square extends Shape {
    side: int

    fn init(side: int) {
        self.side = side
        super.init("square")
    }

    override fn area() -> int { return self.side * self.side }

    static fn unit() -> Square { return new Square(1) }
}

class Circle extends Shape {
    radius: int

    fn init(radius: int) {
        self.radius = radius
        super.init("circle")
    }

    override fn area() -> int {
        return 3 * self.radius * self.radius
    }

    static fn unit() -> Circle { return new Circle(1) }
}

// a third level, so the walk that fills a row has more than two links to
// climb and an inherited body has to survive it
class Pixel extends Square {
    fn init() { super.init(1) }

    static fn only() -> Pixel { return new Pixel() }
}

// ---- a private static beside an inherited instance method ---------------
// `priv` scopes a name to its exact declaring type: the static is not
// inherited and the base's instance method never shared a slot with it, so
// the two coexist. `super.` reaches the instance method and the type name
// reaches the static.

class Ledger {
    fn init() {}

    pub fn stamp() -> string { return "Ledger.stamp" }
}

class SubLedger extends Ledger {
    fn init() { super.init() }

    priv static fn stamp() -> string {
        return "SubLedger.stamp/static"
    }

    fn both() -> string {
        return "{super.stamp()}|{SubLedger.stamp()}"
    }
}

// ---- same name, unrelated classes ---------------------------------------
// Two statics wearing one name in classes with no relation between them
// share the name and nothing else.

class Meters {
    fn init() {}

    static fn unit() -> string { return "m" }
}

class Grams {
    fn init() {}

    static fn unit() -> string { return "g" }
}

// Every receiver arrives as a parameter, so no allocation is in sight and
// the call has to be decided from the type alone.
fn describe(value: Shape) -> string { return value.describe() }

fn stamp(value: Ledger) -> string { return value.stamp() }

fn main() {
    io.println(describe(Shape.origin()))
    io.println(describe(Square.unit()))
    io.println(describe(Circle.unit()))
    io.println(describe(Pixel.only()))
    io.println(describe(new Square(4)))
    io.println(describe(new Circle(2)))

    io.println(stamp(new Ledger()))
    io.println(stamp(new SubLedger()))
    io.println(new SubLedger().both())

    io.println("{Meters.unit()}{Grams.unit()}")
}

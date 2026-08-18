import std.io

class Handlers {
    on_click: fn() -> int = fn() -> int { return 1 }
    on_scale: fn(int) -> int = fn(n: int) -> int { return n * 3 }

    pub fn click() -> int {
        return self.on_click()
    }
    pub fn scale(n: int) -> int {
        return self.on_scale(n)
    }
}

class Fancy extends Handlers {
    pub fn both() -> int {
        return self.on_click() + self.on_scale(2)
    }
}

fn main() {
    let plain: Handlers = new Handlers()
    io.println("direct {plain.on_click()} method {plain.click()}")
    plain.on_scale = fn(n: int) -> int { return n * 10 }
    io.println("swapped {plain.on_scale(4)} via {plain.scale(4)}")
    let fancy: Fancy = new Fancy()
    io.println("inherited {fancy.both()}")
}

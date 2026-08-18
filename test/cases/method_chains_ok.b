import std.io

class Widget {
    total: int = 0
    static fn make(seed: int) -> Widget {
        let w: Widget = new Widget()
        w.total = seed
        return w
    }
    pub fn add(n: int) -> Widget { self.total = self.total + n; return self }
    pub fn double() -> Widget { self.total = self.total * 2; return self }
    pub fn get() -> int { return self.total }
}

fn build_leading() -> int {
    return Widget.make(1)
        .add(2)
        // a comment inside the chain stays transparent
        .double()
        .add(4)
        .get()
}

fn build_trailing() -> int {
    let value: int = Widget.make(2).
        add(3).
        get()
    return value
}

fn find_len(text: string) -> Result<int> {
    let trimmed: string = text
        .trim()
        .to_upper()
    return ok(trimmed.len())
}

fn main() {
    io.println("leading {build_leading()}")
    io.println("trailing {build_trailing()}")
    io.println("string {find_len("  beans  ").or(-1)}")
    let mixed: int = (Widget.make(5)
        .add(5))
        .get()
    io.println("mixed {mixed}")
}

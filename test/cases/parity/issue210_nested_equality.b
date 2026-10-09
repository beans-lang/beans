import std.io

class Item {
    value: int
    fn init(value: int) { self.value = value }
}

fn main() {
    let default_err: Result<Result<int>> = err("outer")
    let inner_err: Result<Result<int>> = ok(err("inner"))
    io.println(default_err == default_err)
    io.println(inner_err == inner_err)
    let default_x: Result<Result<int>> = ok(ok(1))
    io.println(default_x == default_x)
    let a: Result<Result<int, string>, string> = ok(ok(1))
    let b: Result<Result<int, string>, string> = ok(ok(1))
    let c: Result<Result<int, string>, string> = ok(ok(2))
    let d: Result<Result<int, string>, string> = ok(err("inner"))
    let e: Result<Result<int, string>, string> = err("outer")
    let f: Result<Result<int>, Result<int>> = err(ok(3))
    let g: Result<Result<int>, Result<int>> = err(ok(4))
    io.println(a == b)
    io.println(a == c)
    io.println(a == d)
    io.println(d == d)
    io.println(a == e)
    io.println(e == e)
    io.println(f == f)
    io.println(f == g)
    let item: Item = new Item(7)
    let other: Item = new Item(7)
    let x: Result<Item> = ok(item)
    let y: Result<Item> = ok(other)
    io.println(x == x)
    io.println(x == y)
}

import std.io

fn local_total(base: int) -> int {
    let offset: int = base + 1
    let operation: fn(int) -> int =
        fn(value: int) -> int { return value + offset }
    return operation(2) + operation(3)
}

fn generic_total<T>(unused: T, base: int) -> int {
    let offset: int = base + 1
    let operation: fn(int) -> int =
        fn(value: int) -> int { return value + offset }
    return operation(2) + operation(3)
}

fn escaping(base: int) -> fn(int) -> int {
    let offset: int = base
    return fn(value: int) -> int { return value + offset }
}

fn mutable_total(base: int) -> int {
    var offset: int = base
    let operation: fn(int) -> int =
        fn(value: int) -> int { return value + offset }
    offset += 3
    return operation(4)
}

fn main() {
    let escaped: fn(int) -> int = escaping(10)
    let unused: string = "unused"
    io.println(
        "{local_total(5)} {generic_total(unused, 5)} {escaped(4)} {mutable_total(2)}")
}

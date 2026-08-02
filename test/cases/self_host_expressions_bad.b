fn one(value: int) -> int {
    return value
}

class Unordered {
    value: int = 0
}

fn requires_order<T implements Order>(value: T) -> T {
    return value
}

fn missing_clone<T>(values: List<T>) -> List<T> {
    return values.clone()
}

fn broken() -> int {
    let fixed: int = 1
    fixed = 2
    let missing: int = unknown
    let item: Unordered = new Unordered()
    let wrong: Unordered = requires_order(item)
    return one(1, 2)
}

fn main() {
}

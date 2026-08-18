import std.io

enum Value {
    item(number: int)
    empty
}

fn main() {
    let values: List<Value> =
        [Value.item(1), Value.item(2), Value.empty]
    let bytes: List<Bytes> =
        [Bytes.from("ab"), Bytes.from("cd")]

    io.println("equality {values.contains(Value.item(2))} {values.contains(Value.empty)} {values.index_of(Value.item(1)).or(0 - 1)} {bytes.contains(Bytes.from("ab"))} {bytes.index_of(Bytes.from("zz")).or(0 - 1)}")
}

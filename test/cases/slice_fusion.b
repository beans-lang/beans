import std.io

fn main() {
    var values: List<int> = [10, 20, 30, 40]
    var total: int = 0
    for value: int in values.slice(1, 3) {
        total += value
    }
    io.println("stable {total}")

    var seen: int = 0
    for value: int in values.slice(0, 2) {
        seen += value
        values[0] = 99
    }
    io.println("snapshot {seen} current {values[0]}")

    let bytes: Bytes = Bytes.from("abcdef")
    io.println(bytes.slice(1, 5).to_string())
    io.println(bytes.slice(2, 6).to_string_until_nul())
}

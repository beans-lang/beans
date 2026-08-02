import std.io

fn main() {
    var values: Map<int, int> = {1: 10, 2: 20}
    values.reserve(8)
    values[3] = 30
    values[2] = 22
    io.println(values.get(1).or(0))
    io.println(values.get(2).or(0))
    io.println(values.get(9).or(0))
    io.println(values.remove(1))
    io.println(values.remove(1))
    io.println(values.len())

    var labels: Map<int, string> = {1: "one"}
    labels[2] = "label {values.len()}"
    io.println(labels.get(1).or("missing"))
    io.println(labels.get(2).or("missing"))
    io.println(labels.get(3).or("missing"))
    io.println(labels.insert(3, "three"))
    io.println(labels.insert(3, "duplicate {labels.len()}"))
    io.println(labels.get(3).or("missing"))

    var codes: Map<string, int> = {"one": 1}
    codes["two"] = 2
    io.println(codes.insert("three", 3))
    io.println(codes.insert("three", 30))
    io.println(codes.contains("one"))
    io.println(codes.contains("missing"))
    io.println(codes["two"])

    var text: string = "old"
    text = "new {labels.len()}"
    io.println(text)

    var numbers: List<int> = [1]
    numbers = [2, 3]
    io.println(numbers.len())
}

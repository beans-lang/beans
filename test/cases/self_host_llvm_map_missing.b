import std.io

fn main() {
    let values: Map<string, int> = {"one": 1}
    io.println(values["missing"])
}

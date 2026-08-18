import std.io

fn bump(inout n: int, by: int) {
    n += by
}

fn stretch(inout xs: List<int>) {
    xs.push(9)
}

fn relabel(inout name: string) {
    name = "renamed:{name}"
}

fn main() {
    var count: int = 5
    bump(inout count, 3)
    bump(inout count, 2)
    io.println(count)
    var xs: List<int> = [1]
    stretch(inout xs)
    stretch(inout xs)
    io.println("{xs.len()},{xs[1]},{xs[2]}")
    var tag: string = "start"
    relabel(inout tag)
    io.println(tag)
    var names: List<string> = ["a", "b"]
    io.println(names.contains("b"))
    io.println(names.contains("z"))
    var nums: List<int> = [4, 5]
    io.println(nums.contains(5))
    io.println(nums.contains(6))
}

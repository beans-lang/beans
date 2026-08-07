import std.io

fn main() {
    var words: Arena<string> = new Arena(2)
    let first: int = words.add("bean")
    let second: int = words.add("sprout")
    io.println("arena {first} {second} {words.len()} {words.get(first)}")
    words.clear()
    io.println("clear {words.len()} {words.get(first)}")

    let moved: Arena<string> = move words
    words = new Arena(1)
    words.add("new")
    io.println("moved {moved.len()} new {words.get(0)}")
}

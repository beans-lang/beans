import std.io

fn main() {
    let binary: string = "a\0b"
    io.println(binary.len())
    io.println(binary == "a\0b")
    io.println(binary != "a\0c")
    io.println(binary != "a")
    io.println(binary.starts_with("a\0"))
    io.println(binary.ends_with("\0b"))
    io.println(binary.byte_at(2))
    io.println(binary.slice(1, 3).len())
    io.println(" \tbean\n".trim())
    io.println(" left ".trim_start())
    io.println(" right ".trim_end())
    io.println("".is_empty())
    io.println("a\nb\n".lines().join("|"))
    io.println("hello".contains("ell"))
    io.println("hello".contains("xyz"))
    io.println("abc".to_upper())
    io.println("ab".repeat(3))
    io.println("héllo→🌍".count_chars(0, "héllo→🌍".len()))

    let pieces: List<string> = "a,b,c".split(",")
    io.println(pieces.len())
    io.println(pieces.join("-"))
    io.println("item item".replace("item", "row"))
}

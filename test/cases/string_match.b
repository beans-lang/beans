import std.io

fn classify(value: string) -> string {
    return match value {
        "GET" | "HEAD" => "read",
        "POST" => "write",
        "escaped\nvalue" => "escaped",
        "comma,value" | "quoted\"value" => "special",
        _ => "other",
    }
}

fn main() {
    io.println(classify("GET"))
    io.println(classify("HEAD"))
    io.println(classify("POST"))
    io.println(classify("escaped\nvalue"))
    io.println(classify("comma,value"))
    io.println(classify("quoted\"value"))
    io.println(classify("DELETE"))
}

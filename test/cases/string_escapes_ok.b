// \xNN and \u{...}: the two spellings that let a literal hold any byte and
// any codepoint. Written as a byte sweep rather than a couple of examples,
// because an escape table that is right for \x1b and wrong at the 2/3/4-byte
// UTF-8 boundaries would pass a smaller test.
import std.io

fn bytes_of(text: string) -> string {
    var parts: List<string> = []
    for index: int in 0..text.len() {
        parts.push("{text.byte_at(index)}")
    }
    return parts.join(" ")
}

// A byte escape is a byte, whatever it is: above \x7f the string is not
// valid UTF-8 on its own, and that is what makes a protocol writable.
fn raw_bytes() {
    io.println(bytes_of("\x00\x01\x09\x1b\x7f"))
    io.println(bytes_of("\x80\xc3\xa9\xfe\xff"))
    io.println(bytes_of("\xAB\xab\xCd"))
    io.println("{"[\x1b[2J]".len()}")
}

// Every UTF-8 length boundary, both sides.
fn codepoints() {
    io.println(bytes_of("\u{0}"))
    io.println(bytes_of("\u{7f}"))
    io.println(bytes_of("\u{80}"))
    io.println(bytes_of("\u{7ff}"))
    io.println(bytes_of("\u{800}"))
    io.println(bytes_of("\u{d7ff}"))
    io.println(bytes_of("\u{e000}"))
    io.println(bytes_of("\u{ffff}"))
    io.println(bytes_of("\u{10000}"))
    io.println(bytes_of("\u{10FFFF}"))
    io.println(bytes_of("\u{48}\u{49}"))
}

// chars() is the inverse: what it hands back can be written again.
fn chars_inverse() {
    let text: string = "a\u{e9}\u{4e2d}\u{1f600}z"
    io.println(text)
    io.println("{text.len()} {text.chars().len()}")
    let pieces: List<string> = text.chars()
    var lengths: List<string> = []
    for piece: string in pieces {
        lengths.push("{piece.len()}")
    }
    io.println(lengths.join(","))
    io.println("{pieces[1] == "\u{e9}"} {pieces[2] == "\u{4e2d}"} {pieces[3] == "\u{1f600}"}")
}

// An escaped brace is a brace, not a slot — the escape has to be consumed
// whole or the interpolation walker loses the string's structure.
fn braces() {
    let n: int = 7
    io.println("a\u{7b}b{n}c\u{7d}d")
    io.println("\x7b{n}\x7d")
    io.println("\u{7b}\u{7b}{n}\u{7d}\u{7d}")
    io.println("{"\u{7b}"}{n}{"\u{7d}"}")
    io.println("pad {n:4}|\u{7b}")
}

fn kind(value: string) -> string {
    return match value {
        "\x1b" => "esc",
        "\u{a}" => "newline",
        "\u{e9}" | "\xc3\xa9" => "e-acute",
        "\u{7b}" => "brace",
        "\xff" => "high",
        _ => "other",
    }
}

fn patterns() {
    io.println(kind("\x1b"))
    io.println(kind("\n"))
    io.println(kind("\u{e9}"))
    io.println(kind("\{"))
    io.println(kind("\xff"))
    io.println(kind("nope"))
}

// The two spellings of one byte are one string.
fn equality() {
    io.println("{"\x41" == "A"} {"\u{41}" == "A"} {"\u{e9}" == "\xc3\xa9"}")
    io.println("{"\x00".len()} {"\0" == "\x00"} {"\u{0}" == "\0"}")
    var seen: Map<string, int> = {}
    seen["\x1b[0m"] = 1
    io.println("{seen.contains_key("\u{1b}[0m")}")
}

fn main() {
    raw_bytes()
    codepoints()
    chars_inverse()
    braces()
    patterns()
    equality()
}

// One assertion per width rule, so a wrong table names the rule it broke
// instead of only moving a golden. Every line must print nothing.
import std.io

// The two scalars this file needs are invisible in a text editor, so they
// are spelled as the UTF-8 bytes they are.
fn from_bytes(values: List<int>) -> string {
    var out: Bytes = new Bytes(values.len())
    for index: int in 0..values.len() {
        out.set(index, values[index])
    }
    return out.to_string()
}

fn expect(want: int, label: string, s: string) {
    if s.width() != want {
        io.println("{label}: want {want} columns, got {s.width()}")
    }
}

fn main() {
    let soft_hyphen: string = from_bytes([194, 173])          // U+00AD
    let joiner: string = from_bytes([226, 128, 141])          // U+200D
    let zero_width_space: string = from_bytes([226, 128, 139]) // U+200B

    expect(0, "empty", "")
    expect(3, "ascii", "abc")
    expect(0, "controls", "\n\r\t")
    expect(1, "soft hyphen", soft_hyphen)
    expect(0, "zero width space", zero_width_space)
    expect(0, "joiner alone", joiner)
    expect(4, "cjk wide", "東京")
    expect(2, "fullwidth form", "ａ")
    expect(1, "halfwidth kana", "ｱ")
    expect(1, "precomposed accent", "é")
    expect(1, "combining accent", "é")
    expect(2, "conjoining jamo", "각")
    expect(2, "precomposed hangul", "각")
    expect(2, "emoji presentation", "🍜")
    expect(2, "skin tone modifier", "👍🏽")
    expect(2, "zwj sequence", "👨‍👩‍👧‍👦")
    expect(2, "regional pair", "🇯🇵")
    expect(4, "two regional pairs", "🇯🇵🇩🇪")
    // a third indicator starts a new pair and is drawn on its own
    expect(4, "odd regional run", "🇯🇵🇩")
    expect(1, "text pictograph", "❤")
    expect(2, "pictograph plus vs16", "❤️")
    expect(1, "wide emoji plus vs15", "❤︎")
    expect(4, "unassigned cjk block", from_bytes([227, 144, 128, 227, 144, 129]))
    io.println("width rules ok")
}

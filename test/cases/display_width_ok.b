// Display width: the third measure of a string, beside bytes and scalars.
// Every aligned line here would be wrong if `{s:N}` counted bytes.
import std.io
import std.fmt

fn measured(label: string, s: string) {
    io.println("{label} bytes={s.len()} chars={s.chars().len()} cols={s.width()}")
}

fn main() {
    measured("ascii", "abc")
    measured("latin1", "café")
    measured("cjk", "東京")
    measured("mixed", "café 東京 🍜")
    measured("hangul", "가한")
    measured("jamo", "각")
    measured("combining", "é")
    measured("devanagari", "क्षि")
    measured("zwj-family", "👨‍👩‍👧‍👦")
    measured("skin-tone", "👍🏽")
    measured("flag", "🇯🇵")
    measured("two-flags", "🇯🇵🇩🇪")
    measured("heart-text", "❤")
    measured("heart-emoji", "❤️")
    measured("heart-vs15", "❤︎")
    measured("zero-width-space", "a​b")
    measured("controls", "a\tb")
    measured("empty", "")

    // A table only lines up if the pad counts columns.
    let names: List<string> = ["café", "東京", "🍜",
                               "ok", "👨‍👩‍👧"]
    for name: string in names {
        io.println("|{name:8}|{name:-8}|")
    }
    io.println("[{fmt.pad_left("東京", 8)}]")
    io.println("[{fmt.pad_right("東京", 8)}]")

    // Already at or past the asked width comes back untouched.
    io.println("[{fmt.pad_left("東京", 4)}][{fmt.pad_right("東京", 3)}]")
    io.println("[{fmt.pad_left("", 3)}]")

    // Padding applies to the rendered form of any printable value.
    let count: int = 7
    io.println("|{count:5}|{count:-5}|")
}

import std.io
import std.encoding.json

struct Inner {
    pub value: int
}

struct Outer {
    pub inner: Inner
    pub values: List<i16>
}

struct Tiny {
    pub code: i16
}

fn decode(text: string, depth: int) -> Result<Outer> {
    let parse: json.Options = new json.Options()
    parse.allow_comments = true
    parse.allow_trailing_commas = true
    let options: json.DecodeOptions = new json.DecodeOptions()
    options.parse = parse
    options.max_depth = depth
    return json.decode_with_options(text, options)
}

fn show(label: string, result: Result<Outer>) {
    match result {
        ok(value) => io.println(
            "{label}: {value.inner.value} {value.values[0]} {value.values[1]}"),
        err(error) => io.println("{label}: {error.kind}"),
    }
}

fn main() {
    let text: string =
        "/* comment */ \{\"inner\":\{\"value\":7\},\"values\":[-2,300],\}"
    show("allowed", decode(text, 3))
    show("depth", decode(text, 2))
    show("zero", decode(text, 0))
    show("negative", decode(text, -1))
    let decoded_tiny: Result<List<Tiny>> =
        json.decode("[\{\"code\":-3\},\{\"code\":400\}]")
    let tiny: List<Tiny> = (move decoded_tiny).expect("tiny")
    io.println("tiny: {tiny[0].code} {tiny[1].code}")
}

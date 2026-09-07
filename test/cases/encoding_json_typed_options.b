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

// An empty container reaches no deeper than itself, so it is allowed at the
// limit where the same container holding one scalar is not. That difference is
// what separates counting a container's children from visiting them.
struct Holder {
    pub items: List<i16>
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

fn show_holder(label: string, result: Result<Holder>) {
    match result {
        ok(value) => io.println("{label}: {value.items.len()}"),
        err(error) => io.println("{label}: {error.kind}"),
    }
}

fn decode_holder(text: string, depth: int) -> Result<Holder> {
    let options: json.DecodeOptions = new json.DecodeOptions()
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
    // Root is 1, the array is 2, and it holds nothing deeper.
    show_holder("empty-at-limit", decode_holder("\{\"items\":[]\}", 2))
    // The same shape with one scalar puts that scalar at 3.
    show_holder("scalar-past-limit", decode_holder("\{\"items\":[5]\}", 2))
    // ...and 3 is enough for it.
    show_holder("scalar-at-limit", decode_holder("\{\"items\":[5]\}", 3))
    let decoded_tiny: Result<List<Tiny>> =
        json.decode("[\{\"code\":-3\},\{\"code\":400\}]")
    let tiny: List<Tiny> = (move decoded_tiny).expect("tiny")
    io.println("tiny: {tiny[0].code} {tiny[1].code}")
}

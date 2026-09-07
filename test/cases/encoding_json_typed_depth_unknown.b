import std.io
import std.encoding.json

// The depth limit is a policy on the WHOLE document, not only on the fields
// the schema names. A value nested past the limit under a field the schema
// skips (allow_unknown) must still be refused. This pins issue #142: the
// pre-pass that guarantees it is about to be replaced by an inline check that
// must also descend the skipped subtrees. Every case here must give the same
// verdict before and after that change.
@json.allow_unknown
struct Bag {
    pub k: int
}

fn decode(text: string, depth: int) -> Result<Bag> {
    let options: json.DecodeOptions = new json.DecodeOptions()
    options.max_depth = depth
    return json.decode_with_options(text, options)
}

fn show(label: string, result: Result<Bag>) {
    match result {
        ok(value) => io.println("{label}: {value.k}"),
        err(error) => io.println("{label}: {error.kind}"),
    }
}

fn main() {
    // Root is depth 1; the "extra" value sits at depth 2; each further
    // container adds one, and the deepest scalar sits one below its container.

    // n = 0: an empty array under the unknown key reaches only depth 2.
    show("empty-at-limit", decode("\{\"k\":1,\"extra\":[]\}", 2))
    // ...but at max_depth 1 even that empty array (depth 2) is too deep.
    show("empty-past-limit", decode("\{\"k\":1,\"extra\":[]\}", 1))

    // n = 1: one scalar under the unknown key sits at depth 3.
    show("scalar-at-limit", decode("\{\"k\":2,\"extra\":[5]\}", 3))
    show("scalar-past-limit", decode("\{\"k\":2,\"extra\":[5]\}", 2))

    // n = 2: an array of arrays under the unknown key; deepest scalar depth 4.
    show("nested-at-limit", decode("\{\"k\":3,\"extra\":[[5]]\}", 4))
    show("nested-past-limit", decode("\{\"k\":3,\"extra\":[[5]]\}", 3))

    // n = many: five arrays deep under the unknown key; deepest scalar depth 7.
    show("deep-at-limit", decode("\{\"k\":4,\"extra\":[[[[[5]]]]]\}", 7))
    show("deep-past-limit", decode("\{\"k\":4,\"extra\":[[[[[5]]]]]\}", 6))

    // Object nesting under the unknown key, deepest scalar at depth 4.
    show("object-at-limit", decode("\{\"k\":5,\"extra\":\{\"a\":\{\"b\":5\}\}\}", 4))
    show("object-past-limit", decode("\{\"k\":5,\"extra\":\{\"a\":\{\"b\":5\}\}\}", 3))

    // A shallow unknown key is skipped and the object decodes.
    show("shallow-unknown", decode("\{\"k\":6,\"extra\":\"note\"\}", 8))

    // The unknown value can be past the limit while the known value is fine:
    // the refusal is the depth policy, not the type of the skipped value.
    show("string-nested-past-limit",
        decode("\{\"k\":7,\"extra\":[[[\"x\"]]]\}", 3))
}

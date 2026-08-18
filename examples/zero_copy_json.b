// Existing JSON APIs use the fast path; no new language syntax is needed.
// Move a Bytes value into decode_bytes_in_place when the input is no longer
// needed. yyjson then parses that allocation directly instead of copying it.

import std.encoding.json
import std.io

struct Event {
    pub id: u64
    pub name: string
    pub active: bool
}

fn decode_owned(move input: Bytes) -> Result<Event> {
    return json.decode_bytes_in_place(move input)
}

fn main() {
    // Native programs can decode an owned file buffer this way:
    //
    // var input = fs.read_bytes(path)?
    // let event = decode_owned(move input)?
    //
    // Typed decode is compiler-generated and is not run by the reference
    // interpreter yet, so this portable example exercises the DOM path.

    // The normal DOM API also borrows parse input and lookup-key bytes while
    // native yyjson needs them. Returned strings remain normal owned strings.
    match json.parse("\{\"project\":\"beans\"\}") {
        ok(root) => {
            match root.get("project") {
                some(value) => io.println(value.to_string().or("missing")),
                none => io.println("missing"),
            }
        }
        err(error) => io.eprintln(error.msg),
    }
}

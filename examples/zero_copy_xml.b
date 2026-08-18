// Existing XML calls borrow their input directly in native code. When a
// caller no longer needs an owned Bytes buffer, the in-place form also skips
// pugixml's private UTF-8 parse copy.

import std.encoding.xml
import std.io

fn parse_owned(move input: Bytes) -> Result<xml.Document> {
    return xml.parse_bytes_in_place(move input)
}

fn main() {
    let input: Bytes = Bytes.from(
        "<project language=\"beans\"><name>zero copy</name></project>")
    match parse_owned(move input) {
        ok(document) => {
            match document.root() {
                ok(root) => {
                    io.println("{root.name()} {root.attribute("language").or("?")}")
                    for child: xml.Node in root.children() {
                        io.println("{child.name()} {child.text()}")
                    }
                }
                err(error) => io.eprintln(error.msg),
            }
        }
        err(error) => io.eprintln(error.msg),
    }

    // Typed native programs use the same ownership rule:
    // let row: Row = xml.decode_bytes_in_place(move input)?
}

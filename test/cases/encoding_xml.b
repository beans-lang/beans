// std.encoding.xml: declarations, ordered attributes, mixed content,
// comments, CDATA, processing instructions, Unicode, malformed input,
// DOCTYPE rejection, entity safety, deep nesting, node lifetime, and a
// parse/write round trip. Interpreter and native output must be
// byte-identical.

import std.io
import std.encoding.xml

// A node must keep its document alive after the local root is gone.
fn escaped_node() -> xml.Node {
    match xml.parse("<keep alive=\"yes\"><inner>held</inner></keep>") {
        ok(doc) => {
            match doc.root() {
                ok(root) => {
                    for child: xml.Node in root.children() {
                        return child
                    }
                }
                err(_) => {}
            }
        }
        err(_) => {}
    }
    match xml.Document.empty().append_element("fallback") {
        ok(node) => { return node }
        err(_) => {}
    }
    return xml.Document.empty().append_element("fallback").expect("node")
}

fn check_parse_error(label: string, text: string) {
    match xml.parse(text) {
        ok(_) => io.println("{label}: accepted"),
        err(e) => io.println("{label}: {e.kind} - {e.msg}"),
    }
}

fn bom_case(label: string, prefix: List<int>, body: string, wide: int) {
    var data: Bytes = new Bytes(0)
    for piece: int in prefix { data.push(piece) }
    for index: int in 0..body.len() {
        data.push(body.byte_at(index))
        for pad: int in 0..wide { data.push(0) }
    }
    match xml.parse_bytes(data) {
        ok(doc) => {
            match doc.root() {
                ok(root) => io.println("{label}: root [{root.name()}] text [{root.text()}]"),
                err(e) => io.println("{label}: {e.msg}"),
            }
        }
        err(e) => io.println("{label}: {e.kind} - {e.msg}"),
    }
}

fn big_endian_case(label: string, prefix: List<int>, body: string, wide: int) {
    var data: Bytes = new Bytes(0)
    for piece: int in prefix { data.push(piece) }
    for index: int in 0..body.len() {
        for pad: int in 0..wide { data.push(0) }
        data.push(body.byte_at(index))
    }
    match xml.parse_bytes(data) {
        ok(doc) => {
            match doc.root() {
                ok(root) => io.println("{label}: root [{root.name()}] text [{root.text()}]"),
                err(e) => io.println("{label}: {e.msg}"),
            }
        }
        err(e) => io.println("{label}: {e.kind} - {e.msg}"),
    }
}

fn doctype_case(label: string, prefix: List<int>, wide: int, big_end: bool) {
    let body: string = "<!DOCTYPE r><r/>"
    var data: Bytes = new Bytes(0)
    for piece: int in prefix { data.push(piece) }
    for index: int in 0..body.len() {
        if big_end {
            for pad: int in 0..wide { data.push(0) }
            data.push(body.byte_at(index))
        } else {
            data.push(body.byte_at(index))
            for pad: int in 0..wide { data.push(0) }
        }
    }
    match xml.parse_bytes(data) {
        ok(_) => io.println("{label}: accepted"),
        err(e) => io.println("{label}: {e.kind} - {e.msg}"),
    }
}

fn main() {
    let source: string = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><!-- top --><?robot spin?><shop:order z=\"last\" a=\"first\" a2=\"2\">text <b>bold</b> tail<![CDATA[<raw> & bytes]]><!-- note --><?do it?></shop:order>"
    match xml.parse(source) {
        ok(doc) => {
            for node: xml.Node in doc.nodes() {
                io.println("top {node.kind()} name [{node.name()}] value [{node.value()}]")
            }
            match doc.declaration() {
                some(decl) => {
                    io.println("decl version {decl.attribute("version").or("?")} encoding {decl.attribute("encoding").or("?")}")
                }
                none => io.println("no decl"),
            }
            match doc.root() {
                ok(root) => {
                    io.println("root [{root.name()}] prefix [{root.prefix()}] local [{root.local_name()}]")
                    for attr: xml.Attribute in root.attributes() {
                        io.println("attr {attr.name}={attr.value}")
                    }
                    io.println("attr lookup {root.attribute("a").or("?")} missing {root.attribute("nope").is_none()}")
                    for child: xml.Node in root.children() {
                        io.println("child {child.kind()} [{child.name()}] [{child.value()}]")
                    }
                    io.println("text [{root.text()}]")
                }
                err(e) => io.println("err {e.msg}"),
            }
            // round trip: compact write reproduces the input byte for byte
            match xml.stringify(doc) {
                ok(text) => {
                    let verdict: string =
                        if text == source { "exact" } else { text }
                    io.println("roundtrip {verdict}")
                }
                err(e) => io.println("err {e.msg}"),
            }
        }
        err(e) => io.println("parse err {e.msg}"),
    }

    // unicode content and attribute values
    match xml.parse("<r é=\"café\">🙂 &amp; &#233;</r>") {
        ok(doc) => {
            match doc.root() {
                ok(root) => {
                    io.println("unicode text [{root.text()}] attr [{root.attribute("é").or("?")}]")
                }
                err(e) => io.println("err {e.msg}"),
            }
        }
        err(e) => io.println("unicode err {e.msg}"),
    }

    // malformed documents report positions
    check_parse_error("mismatch", "<a><b></a>")
    check_parse_error("unclosed", "<a>")
    check_parse_error("bad attr", "<a x=1></a>")
    check_parse_error("bad comment", "<a><!-- x --></a><!--")
    check_parse_error("bad cdata", "<a><![CDATA[x]]</a>")

    // exactly one root element, checked in both directions
    check_parse_error("zero roots (empty)", "")
    check_parse_error("zero roots (spaces)", "   ")
    check_parse_error("zero roots (decl)", "<?xml version=\"1.0\"?>")
    check_parse_error("zero roots (comment)", "<!--only a comment-->")
    check_parse_error("zero roots (pi)", "<?target data?>")
    check_parse_error("zero roots (doctype)", "<!DOCTYPE r>")
    check_parse_error("two roots", "<a/><b/>")
    check_parse_error("three roots", "<a/><b/><c/>")
    // trailing misc after the root element is well-formed XML
    check_parse_error("root plus trailing misc", "<a/><!--after-->")
    match xml.parse("<!--before--><a/><?after it?>") {
        ok(doc) => {
            io.println("one root among siblings: {doc.nodes().len()} top nodes")
        }
        err(e) => io.println("one root rejected: {e.msg}"),
    }

    // byte-order marks: UTF-8, UTF-16 (both ends), UTF-32 (both ends)
    // UTF-8 with and without a BOM
    bom_case("utf8 bom", [0xef, 0xbb, 0xbf], "<r>hi</r>", 0)
    bom_case("utf8 plain", [], "<r>hi</r>", 0)
    // UTF-16LE: BOM FF FE, then each ASCII byte followed by one zero
    bom_case("utf16le bom", [0xff, 0xfe], "<r>hi</r>", 1)
    // UTF-32LE: BOM FF FE 00 00, then each byte followed by three zeros
    bom_case("utf32le bom", [0xff, 0xfe, 0x00, 0x00], "<r>hi</r>", 3)

    // UTF-16BE and UTF-32BE put the zero padding first
    big_endian_case("utf16be bom", [0xfe, 0xff], "<r>hi</r>", 1)
    big_endian_case("utf32be bom", [0x00, 0x00, 0xfe, 0xff], "<r>hi</r>", 3)

    // DOCTYPE stays rejected under every encoding, and a transcoded input
    // says so rather than quoting an offset into a buffer the caller never
    // saw. A UTF-8 input keeps its exact offset, BOM included.
    doctype_case("doctype utf8", [], 0, false)
    doctype_case("doctype utf8 bom", [0xef, 0xbb, 0xbf], 0, false)
    doctype_case("doctype utf16le", [0xff, 0xfe], 1, false)
    doctype_case("doctype utf16be", [0xfe, 0xff], 1, true)
    doctype_case("doctype utf32le", [0xff, 0xfe, 0x00, 0x00], 3, false)

    // a malformed UTF-8 document keeps its exact offset even behind a BOM
    var bom_bad: Bytes = new Bytes(0)
    bom_bad.push(0xef)
    bom_bad.push(0xbb)
    bom_bad.push(0xbf)
    bom_bad.append_string("<a><b></a>")
    match xml.parse_bytes(bom_bad) {
        ok(_) => io.println("bom mismatch accepted"),
        err(e) => io.println("bom mismatch: {e.msg}"),
    }

    // DOCTYPE is rejected by default, with the offset of the declaration
    check_parse_error("doctype", "<!DOCTYPE note SYSTEM \"http://evil.example/x.dtd\"><note/>")
    check_parse_error("doctype entity", "<!DOCTYPE r [<!ENTITY x SYSTEM \"file:///etc/passwd\">]><r>&x;</r>")

    // opted in, the doctype is inert data: no file is read, no entity is
    // defined, and the unknown reference stays literal text
    var permissive: xml.Options = new xml.Options()
    permissive.allow_doctype = true
    match xml.parse_with_options("<!DOCTYPE r [<!ENTITY x SYSTEM \"file:///etc/passwd\">]><r>&x;</r>", permissive) {
        ok(doc) => {
            for node: xml.Node in doc.nodes() {
                io.println("permissive {node.kind()}")
            }
            match doc.root() {
                ok(root) => {
                    let body: string = root.text()
                    io.println("entity literal {body.contains("&x;")} leaked {body.contains("root:")}")
                }
                err(e) => io.println("err {e.msg}"),
            }
        }
        err(e) => io.println("permissive err {e.msg}"),
    }

    // whitespace-only text nodes are dropped by default, kept on request
    match xml.parse("<a> <b/> </a>") {
        ok(doc) => {
            match doc.root() {
                ok(root) => io.println("default children {root.children().len()}"),
                err(e) => io.println("err {e.msg}"),
            }
        }
        err(e) => io.println("err {e.msg}"),
    }
    var spacey: xml.Options = new xml.Options()
    spacey.preserve_space_text = true
    match xml.parse_with_options("<a> <b/> </a>", spacey) {
        ok(doc) => {
            match doc.root() {
                ok(root) => io.println("preserved children {root.children().len()}"),
                err(e) => io.println("err {e.msg}"),
            }
        }
        err(e) => io.println("err {e.msg}"),
    }

    // node lifetime beyond its document's root binding
    let survivor: xml.Node = escaped_node()
    io.println("survivor [{survivor.name()}] [{survivor.text()}]")

    // builders: declaration, nesting, attributes, escaping, pretty output
    let built: xml.Document = xml.Document.empty()
    built.append_declaration("1.0", "UTF-8").expect("decl")
    built.append_comment(" made by beans ").expect("comment")
    match built.append_element("order") {
        ok(order) => {
            order.set_attribute("id", "7").expect("attr")
            order.set_attribute("note", "a<b&\"c\"").expect("attr")
            match order.set_attribute("id", "8") {
                ok(_) => io.println("dup attr accepted"),
                err(e) => io.println("dup attr {e.kind}"),
            }
            match order.append_element("item") {
                ok(item) => {
                    item.append_text("first & last").expect("text")
                    item.append_cdata("<raw/>").expect("cdata")
                }
                err(e) => io.println("err {e.msg}"),
            }
            order.append_processing_instruction("target", "data here").expect("pi")
        }
        err(e) => io.println("err {e.msg}"),
    }
    match xml.stringify(built) {
        ok(text) => io.println("built {text}"),
        err(e) => io.println("err {e.msg}"),
    }
    match xml.stringify_pretty(built, "  ") {
        ok(text) => io.print("pretty:\n{text}"),
        err(e) => io.println("err {e.msg}"),
    }
    match xml.stringify_pretty(built, "\t\t") {
        ok(text) => io.println("tabs ok {text.len() > 0}"),
        err(e) => io.println("err {e.msg}"),
    }

    // a built document round-trips through parse
    match xml.stringify(built) {
        ok(text) => {
            match xml.parse(text) {
                ok(again) => {
                    match again.root() {
                        ok(root) => io.println("reparse root [{root.name()}] attrs {root.attributes().len()}"),
                        err(e) => io.println("err {e.msg}"),
                    }
                }
                err(e) => io.println("reparse err {e.msg}"),
            }
        }
        err(e) => io.println("err {e.msg}"),
    }

    // deep nesting parses and frees without recursion limits
    var deep: List<string> = []
    for level: int in 0..3000 { deep.push("<d>") }
    deep.push("x")
    for level: int in 0..3000 { deep.push("</d>") }
    match xml.parse(deep.join("")) {
        ok(doc) => {
            var depth: int = 0
            match doc.root() {
                ok(top) => {
                    var cursor: xml.Node = top
                    var walking: bool = true
                    for walking {
                        depth += 1
                        walking = false
                        for child: xml.Node in cursor.children() {
                            let raw: xml.NodeKind = child.kind()
                            match raw {
                                element => {
                                    cursor = child
                                    walking = true
                                }
                                _ => {}
                            }
                        }
                    }
                }
                err(_) => {}
            }
            io.println("deep depth {depth}")
        }
        err(e) => io.println("deep err {e.msg}"),
    }

    // repeated parse/free loops
    var checksum: int = 0
    for round: int in 0..2000 {
        match xml.parse("<a x=\"1\"><b>t</b><!--c--></a>") {
            ok(doc) => {
                match doc.root() {
                    ok(root) => { checksum += root.children().len() }
                    err(_) => {}
                }
            }
            err(_) => {}
        }
    }
    io.println("loop checksum {checksum}")
}

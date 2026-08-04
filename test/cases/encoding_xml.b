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
    match xml.Document.new_document().append_element("fallback") {
        ok(node) => { return node }
        err(_) => {}
    }
    return xml.Document.new_document().append_element("fallback").expect("node")
}

fn check_parse_error(label: string, text: string) {
    match xml.parse(text) {
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
    check_parse_error("two roots", "<a/><b/>")
    check_parse_error("empty", "")
    check_parse_error("bad comment", "<a><!-- x --></a><!--")
    check_parse_error("bad cdata", "<a><![CDATA[x]]</a>")

    // DOCTYPE is rejected by default, with the offset of the declaration
    check_parse_error("doctype", "<!DOCTYPE note SYSTEM \"http://evil.example/x.dtd\"><note/>")
    check_parse_error("doctype entity", "<!DOCTYPE r [<!ENTITY x SYSTEM \"file:///etc/passwd\">]><r>&x;</r>")

    // opted in, the doctype is inert data: no file is read, no entity is
    // defined, and the unknown reference stays literal text
    var permissive: xml.Options = new xml.Options()
    permissive.allow_doctype = true
    match xml.parse_with("<!DOCTYPE r [<!ENTITY x SYSTEM \"file:///etc/passwd\">]><r>&x;</r>", permissive) {
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
    match xml.parse_with("<a> <b/> </a>", spacey) {
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
    let built: xml.Document = xml.Document.new_document()
    built.append_declaration("1.0", "UTF-8").expect("decl")
    built.append_comment(" made by beans ").expect("comment")
    match built.append_element("order") {
        ok(order) => {
            order.set_attr("id", "7").expect("attr")
            order.set_attr("note", "a<b&\"c\"").expect("attr")
            match order.set_attr("id", "8") {
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
            order.append_instruction("target", "data here").expect("pi")
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

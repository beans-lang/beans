// XML over the vendored pugixml bridge (runtime/encoding).
//
// This is a DOM API, not a streaming one: parse materializes the whole
// document and Nodes are views into it. A Node keeps its document alive
// through a shared owner object, so a child stays valid after the local
// variable holding its root is gone.
//
// DOM names stay qualified names. Typed decoding can instead match a local
// name and namespace URI with `@xml.namespace`, so input prefixes may vary.
//
// Security defaults:
//   - DOCTYPE is rejected by default with its byte offset; opting in with
//     `Options.allow_doctype` only keeps the declaration as an inert node.
//   - pugixml expands only the five built-in entities and numeric character
//     references. There is no external-entity mechanism: parsing never
//     touches the filesystem or the network.
//
// Mixed content order is preserved: `children()` returns text, elements,
// CDATA, comments and processing instructions exactly as they appear.
// Whitespace-only text nodes are dropped unless `Options.
// preserve_space_text` is set (pugixml's parse_ws_pcdata).
//
// Escaping and serialization are pugixml's own writer; nothing is written
// by hand here.

package xml

/// Automatic field-name conversion for typed XML decoding.
pub enum Naming {
    exact
    camel_case
    snake_case
}

/// Overrides a field element/attribute name, or a struct root/item name.
@target(value: ["type", "field"])
@retention(value: "tool")
pub annotation name {
    value: string
}

/// Matches a typed struct root or field by XML namespace URI and local name.
@target(value: ["type", "field"])
@retention(value: "tool")
pub annotation namespace {
    value: string
}

/// Maps a field from an XML attribute instead of a child element.
@target(value: ["field"])
@retention(value: "tool")
pub annotation attribute {}

/// Maps one field from the containing element's text content.
@target(value: ["field"])
@retention(value: "tool")
pub annotation text {}

/// Leaves a field out of automatic XML decoding.
@target(value: ["field"])
@retention(value: "tool")
pub annotation ignore {}

/// Selects the default XML naming rule for one struct.
@target(value: ["type"])
@retention(value: "tool")
pub annotation naming {
    value: Naming = Naming.exact
}

/// Lets a struct ignore XML attributes/elements it does not declare.
@target(value: ["type"])
@retention(value: "tool")
pub annotation allow_unknown {}

extern "C" fn beans_enc_xml_parse(source: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_enc_xml_new_doc() -> int
extern "C" fn beans_enc_xml_doc_root(doc: int) -> int
extern "C" fn beans_enc_xml_free_doc(doc: int) -> int
extern "C" fn beans_enc_xml_node_kind(node: int) -> int
extern "C" fn beans_enc_xml_name_len(node: int) -> int
extern "C" fn beans_enc_xml_name_copy(node: int, target: RawPtr<u8>) -> int
extern "C" fn beans_enc_xml_value_len(node: int) -> int
extern "C" fn beans_enc_xml_value_copy(node: int, target: RawPtr<u8>) -> int
extern "C" fn beans_enc_xml_child_count(node: int) -> int
extern "C" fn beans_enc_xml_children(node: int, out: RawPtr<u64>) -> int
extern "C" fn beans_enc_xml_attr_count(node: int) -> int
extern "C" fn beans_enc_xml_attrs_words(node: int) -> int
extern "C" fn beans_enc_xml_attrs_pack(node: int, out: RawPtr<u64>) -> int
extern "C" fn beans_enc_xml_attrs_refs(node: int, out: RawPtr<u64>) -> int
extern "C" fn beans_enc_xml_attr_get(name: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_enc_xml_attr_value_len(attr: int) -> int
extern "C" fn beans_enc_xml_attr_value_copy(attr: int, target: RawPtr<u8>) -> int
extern "C" fn beans_enc_xml_append_node(name: RawPtr<u8>, value: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_enc_xml_set_attr(name: RawPtr<u8>, value: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_enc_xml_write(indent: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_enc_xml_take_buf(buf: int, len: int, target: RawPtr<u8>) -> int

// Native code replaces these private helpers with borrowed addresses and one
// exact final-string allocation. Interpreters use the raw-buffer fallbacks.
fn enc_bytes_address(data: Bytes) -> int {
    return 0
}

fn enc_string_address(text: string) -> int {
    return 0
}

fn enc_string_uninit(length: int) -> string {
    return ""
}

// ---- raw-buffer marshalling (word-at-a-time, no per-byte Beans calls) ----

// Bulk copy through the public Bytes pointer bridge. This is one memcpy on
// both native and interpreted paths and does not assume word alignment.
fn raw_copy_from_bytes(data: Bytes, from: int, address: int, count: int) {
    if from < 0 || count < 0 || from + count > data.len() {
        panic("encoding raw copy out of range")
    }
    if count == 0 { return }
    unsafe {
        let target: RawPtr<u8> = RawPtr.from_address(address as u64)
        target.copy_from(data.as_ptr().offset(from), count)
    }
}

fn raw_copy_to_bytes(address: int, target: Bytes, at: int, count: int) {
    if at < 0 || count < 0 || at + count > target.len() {
        panic("encoding raw copy out of range")
    }
    if count == 0 { return }
    unsafe {
        let source: RawPtr<u8> = RawPtr.from_address(address as u64)
        target.as_ptr().offset(at).copy_from(source, count)
    }
}

fn raw_from_bytes(data: Bytes) -> int {
    let count: int = data.len()
    let address: int = alloc_words((count + 7) / 8)
    raw_copy_from_bytes(data, 0, address, count)
    return address
}

fn bytes_from_raw(address: int, count: int) -> Bytes {
    unsafe {
        return Bytes.from_raw(RawPtr.from_address(address as u64), count)
    }
}

fn free_raw(address: int) {
    unsafe {
        let block: RawPtr<u8> = RawPtr.from_address(address as u64)
        block.free()
    }
}

fn alloc_words(count: int) -> int {
    var address: int = 0
    unsafe {
        let block: RawPtr<u64> = RawPtr.alloc(if count == 0 { 1 } else { count })
        address = block.address() as int
    }
    return address
}

/// The node kinds a parsed document can contain.
pub enum NodeKind {
    element
    text
    cdata
    comment
    processing_instruction
    declaration
    doctype
}

/// Parse behaviour. Both fields default to the safe, lean setting.
pub class Options {
    pub allow_doctype: bool = false
    pub preserve_space_text: bool = false

    fn flag_bits() -> int {
        var bits: int = 0
        if self.allow_doctype { bits = bits | 1 }
        if self.preserve_space_text { bits = bits | 2 }
        return bits
    }
}

/// One attribute, in declaration order.
pub struct Attribute {
    pub name: string
    pub value: string
}

// The shared owner of one pugixml document; freed when the last Document or
// Node over it is dropped.
class DocOwner {
    handle: int
    buffer: Option<Bytes>

    fn init(handle: int, move buffer: Option<Bytes>) {
        self.handle = handle
        self.buffer = move buffer
    }

    fn deinit() {
        if self.handle != 0 {
            unsafe {
                beans_enc_xml_free_doc(self.handle)
            }
        }
    }
}

fn node_name(handle: int) -> string {
    var length: int = 0
    unsafe {
        length = beans_enc_xml_name_len(handle)
    }
    if length == 0 { return "" }
    let direct: string = enc_string_uninit(length)
    let direct_address: int = enc_string_address(direct)
    if direct_address != 0 {
        unsafe {
            let target: RawPtr<u8> =
                RawPtr.from_address(direct_address as u64)
            beans_enc_xml_name_copy(handle, target)
        }
        return direct
    }
    let block: int = alloc_words((length + 7) / 8)
    unsafe {
        let view: RawPtr<u8> = RawPtr.from_address(block as u64)
        beans_enc_xml_name_copy(handle, view)
    }
    let text: string = bytes_from_raw(block, length).to_string()
    free_raw(block)
    return text
}

fn node_value(handle: int) -> string {
    var length: int = 0
    unsafe {
        length = beans_enc_xml_value_len(handle)
    }
    if length == 0 { return "" }
    let direct: string = enc_string_uninit(length)
    let direct_address: int = enc_string_address(direct)
    if direct_address != 0 {
        unsafe {
            let target: RawPtr<u8> =
                RawPtr.from_address(direct_address as u64)
            beans_enc_xml_value_copy(handle, target)
        }
        return direct
    }
    let block: int = alloc_words((length + 7) / 8)
    unsafe {
        let view: RawPtr<u8> = RawPtr.from_address(block as u64)
        beans_enc_xml_value_copy(handle, view)
    }
    let text: string = bytes_from_raw(block, length).to_string()
    free_raw(block)
    return text
}

// Appends one node under `parent` (0 = document top level) and wraps it.
fn append_under(owner: DocOwner, parent: int, kind: int,
                name: string, value: string) -> Result<Node> {
    let borrowed_name: int = enc_string_address(name)
    let borrowed_value: int = enc_string_address(value)
    let name_bytes: Bytes = if borrowed_name == 0 {
        Bytes.from(name)
    } else { new Bytes(0) }
    let value_bytes: Bytes = if borrowed_value == 0 {
        Bytes.from(value)
    } else { new Bytes(0) }
    let name_block: int = if borrowed_name == 0 {
        raw_from_bytes(name_bytes)
    } else { borrowed_name }
    let value_block: int = if borrowed_value == 0 {
        raw_from_bytes(value_bytes)
    } else { borrowed_value }
    var status: int = 0
    var handle: int = 0
    unsafe {
        let name_view: RawPtr<u8> = RawPtr.from_address(name_block as u64)
        let value_view: RawPtr<u8> = RawPtr.from_address(value_block as u64)
        let req: RawPtr<u64> = RawPtr.alloc(6)
        req.write(owner.handle as u64)
        req.offset(1).write(parent as u64)
        req.offset(2).write(kind as u64)
        req.offset(3).write(name.len() as u64)
        req.offset(4).write(value.len() as u64)
        status = beans_enc_xml_append_node(name_view, value_view, req)
        handle = req.offset(5).read() as int
        req.free()
    }
    if borrowed_name == 0 { free_raw(name_block) }
    if borrowed_value == 0 { free_raw(value_block) }
    if status != 0 {
        return err("cannot append this node here", "invalid")
    }
    return ok(new Node(owner, handle))
}

/// A node view into its document. Copying is cheap; the document is freed
/// when the last Document or Node over it is dropped.
pub class Node {
    owner: DocOwner
    handle: int

    fn init(owner: DocOwner, handle: int) {
        self.owner = owner
        self.handle = handle
    }

    pub fn kind() -> NodeKind {
        var raw: int = 0
        unsafe {
            raw = beans_enc_xml_node_kind(self.handle)
        }
        return match raw {
            1 => NodeKind.element,
            2 => NodeKind.text,
            3 => NodeKind.cdata,
            4 => NodeKind.comment,
            5 => NodeKind.processing_instruction,
            6 => NodeKind.declaration,
            _ => NodeKind.doctype,
        }
    }

    /// The raw qualified name — for `<soap:Body>` this is "soap:Body".
    pub fn name() -> string {
        return node_name(self.handle)
    }

    /// The part before the colon, or "" when the name has none.
    pub fn prefix() -> string {
        let qualified: string = node_name(self.handle)
        match qualified.find(":") {
            some(at) => { return qualified.slice(0, at) }
            none => { return "" }
        }
    }

    /// The part after the colon, or the whole name when it has none.
    pub fn local_name() -> string {
        let qualified: string = node_name(self.handle)
        match qualified.find(":") {
            some(at) => {
                return qualified.slice(at + 1, qualified.len())
            }
            none => { return qualified }
        }
    }

    /// The node's own value: text and CDATA content, a comment's body, a
    /// processing instruction's payload. Elements report "" — their text
    /// lives in child nodes; see `text()`.
    pub fn value() -> string {
        return node_value(self.handle)
    }

    /// Direct text and CDATA children concatenated in order — the usual
    /// "what does this element say" accessor for mixed content.
    pub fn text() -> string {
        var pieces: List<string> = []
        for child: Node in self.children() {
            let raw: NodeKind = child.kind()
            match raw {
                text => { pieces.push(child.value()) }
                cdata => { pieces.push(child.value()) }
                _ => {}
            }
        }
        return pieces.join("")
    }

    /// Every child in document order — mixed content included.
    pub fn children() -> List<Node> {
        var count: int = 0
        unsafe {
            count = beans_enc_xml_child_count(self.handle)
        }
        var found: List<Node> = []
        if count == 0 { return move found }
        found.reserve(count)
        let block: int = alloc_words(count)
        unsafe {
            let view: RawPtr<u64> = RawPtr.from_address(block as u64)
            beans_enc_xml_children(self.handle, view)
            for index: int in 0..count {
                found.push(new Node(self.owner,
                                    view.offset(index).read() as int))
            }
        }
        free_raw(block)
        return move found
    }

    /// Every attribute in declaration order.
    pub fn attributes() -> List<Attribute> {
        let direct_text: bool = enc_string_address("x") != 0
        var count: int = 0
        var words: int = 0
        unsafe {
            count = beans_enc_xml_attr_count(self.handle)
            words = if direct_text {
                count * 4
            } else {
                beans_enc_xml_attrs_words(self.handle)
            }
        }
        var found: List<Attribute> = []
        if words == 0 { return move found }
        found.reserve(count)
        let block: int = alloc_words(words)
        unsafe {
            let view: RawPtr<u64> = RawPtr.from_address(block as u64)
            if direct_text {
                beans_enc_xml_attrs_refs(self.handle, view)
            } else {
                beans_enc_xml_attrs_pack(self.handle, view)
            }
            var cursor: int = 0
            for cursor < words {
                let name_len: int = view.offset(cursor).read() as int
                let name_address: int = if direct_text {
                    view.offset(cursor + 1).read() as int
                } else {
                    view.offset(cursor + 1).address() as int
                }
                cursor += if direct_text {
                    2
                } else {
                    1 + (name_len + 7) / 8
                }
                let value_len: int = view.offset(cursor).read() as int
                let value_address: int = if direct_text {
                    view.offset(cursor + 1).read() as int
                } else {
                    view.offset(cursor + 1).address() as int
                }
                cursor += if direct_text {
                    2
                } else {
                    1 + (value_len + 7) / 8
                }
                let name_text: string =
                    copied_text(name_address, name_len)
                let value_text: string =
                    copied_text(value_address, value_len)
                found.push(Attribute { name: name_text, value: value_text })
            }
        }
        free_raw(block)
        return move found
    }

    /// First attribute with this qualified name, or none.
    pub fn attribute(name: string) -> Option<string> {
        let borrowed: int = enc_string_address(name)
        if borrowed != 0 {
            var attr: int = 0
            unsafe {
                let source: RawPtr<u8> =
                    RawPtr.from_address(borrowed as u64)
                let req: RawPtr<u64> = RawPtr.alloc(3)
                req.write(self.handle as u64)
                req.offset(1).write(name.len() as u64)
                beans_enc_xml_attr_get(source, req)
                attr = req.offset(2).read() as int
                req.free()
            }
            if attr == 0 { return none }
            var length: int = 0
            unsafe {
                length = beans_enc_xml_attr_value_len(attr)
            }
            if length == 0 { return some("") }
            let direct: string = enc_string_uninit(length)
            let direct_address: int = enc_string_address(direct)
            unsafe {
                let target: RawPtr<u8> =
                    RawPtr.from_address(direct_address as u64)
                beans_enc_xml_attr_value_copy(attr, target)
            }
            return some(direct)
        }
        for attr: Attribute in self.attributes() {
            if attr.name == name { return some(attr.value) }
        }
        return none
    }

    // ---- building ----

    pub fn append_element(name: string) -> Result<Node> {
        return append_under(self.owner, self.handle, 1, name, "")
    }

    pub fn append_text(value: string) -> Result<Node> {
        return append_under(self.owner, self.handle, 2, "", value)
    }

    pub fn append_cdata(value: string) -> Result<Node> {
        return append_under(self.owner, self.handle, 3, "", value)
    }

    pub fn append_comment(value: string) -> Result<Node> {
        return append_under(self.owner, self.handle, 4, "", value)
    }

    pub fn append_processing_instruction(name: string, value: string) -> Result<Node> {
        return append_under(self.owner, self.handle, 5, name, value)
    }

    /// Adds one attribute. A duplicate qualified name on the same element is
    /// refused: parsed documents may carry duplicates (reported in order by
    /// `attributes()`), but building one on purpose is almost always a bug.
    pub fn set_attribute(name: string, value: string) -> Result<bool> {
        match self.attribute(name) {
            some(_) => {
                return err("attribute {name} is already set on this element", "exists")
            }
            none => {}
        }
        let borrowed_name: int = enc_string_address(name)
        let borrowed_value: int = enc_string_address(value)
        let name_bytes: Bytes = if borrowed_name == 0 {
            Bytes.from(name)
        } else { new Bytes(0) }
        let value_bytes: Bytes = if borrowed_value == 0 {
            Bytes.from(value)
        } else { new Bytes(0) }
        let name_block: int = if borrowed_name == 0 {
            raw_from_bytes(name_bytes)
        } else { borrowed_name }
        let value_block: int = if borrowed_value == 0 {
            raw_from_bytes(value_bytes)
        } else { borrowed_value }
        var status: int = 0
        unsafe {
            let name_view: RawPtr<u8> = RawPtr.from_address(name_block as u64)
            let value_view: RawPtr<u8> = RawPtr.from_address(value_block as u64)
            let req: RawPtr<u64> = RawPtr.alloc(3)
            req.write(self.handle as u64)
            req.offset(1).write(name.len() as u64)
            req.offset(2).write(value.len() as u64)
            status = beans_enc_xml_set_attr(name_view, value_view, req)
            req.free()
        }
        if borrowed_name == 0 { free_raw(name_block) }
        if borrowed_value == 0 { free_raw(value_block) }
        if status != 0 {
            return err("cannot set attribute {name} here", "invalid")
        }
        return ok(true)
    }
}

// Copies one borrowed or packed payload straight into its final string on
// native builds. Interpreters use Bytes.from_raw for the same bytes.
fn copied_text(address: int, len: int) -> string {
    if len == 0 { return "" }
    let direct: string = enc_string_uninit(len)
    let direct_address: int = enc_string_address(direct)
    if direct_address != 0 {
        unsafe {
            let source: RawPtr<u8> = RawPtr.from_address(address as u64)
            let target: RawPtr<u8> =
                RawPtr.from_address(direct_address as u64)
            target.copy_from(source, len)
        }
        return direct
    }
    return bytes_from_raw(address, len).to_string()
}

/// A whole XML document. Parse one, or build one from `Document.empty()`.
pub class Document {
    owner: DocOwner
    root_handle: int

    fn init(owner: DocOwner, root_handle: int) {
        self.owner = owner
        self.root_handle = root_handle
    }

    /// An empty document to build into.
    pub static fn empty() -> Document {
        var handle: int = 0
        unsafe {
            handle = beans_enc_xml_new_doc()
        }
        var root: int = 0
        unsafe {
            root = beans_enc_xml_doc_root(handle)
        }
        return new Document(new DocOwner(handle, none), root)
    }

    /// Every top-level node in order: declaration, comments, processing
    /// instructions, the root element, and (opted-in) doctype.
    pub fn nodes() -> List<Node> {
        let top: Node = new Node(self.owner, self.root_handle)
        return top.children()
    }

    /// The `<?xml ...?>` declaration, when the document has one.
    pub fn declaration() -> Option<Node> {
        for node: Node in self.nodes() {
            let raw: NodeKind = node.kind()
            match raw {
                declaration => { return some(node) }
                _ => {}
            }
        }
        return none
    }

    /// The root element.
    pub fn root() -> Result<Node> {
        for node: Node in self.nodes() {
            let raw: NodeKind = node.kind()
            match raw {
                element => { return ok(node) }
                _ => {}
            }
        }
        return err("document has no root element", "not_found")
    }

    // ---- building (top level) ----

    pub fn append_element(name: string) -> Result<Node> {
        return append_under(self.owner, 0, 1, name, "")
    }

    pub fn append_comment(value: string) -> Result<Node> {
        return append_under(self.owner, 0, 4, "", value)
    }

    pub fn append_processing_instruction(name: string, value: string) -> Result<Node> {
        return append_under(self.owner, 0, 5, name, value)
    }

    /// Adds `<?xml version="..." encoding="..."?>`. Pass "" to omit the
    /// encoding attribute.
    pub fn append_declaration(version: string, encoding: string) -> Result<Node> {
        let node: Node = append_under(self.owner, 0, 6, "", "")?
        node.set_attribute("version", version)?
        if encoding != "" {
            node.set_attribute("encoding", encoding)?
        }
        return ok(node)
    }
}

fn parse_phrase(code: int) -> string {
    // pugixml 1.16's xml_parse_status values, rendered here so both backends
    // print identical text.
    return match code {
        3 => "out of memory",
        4 => "internal parser error",
        5 => "unrecognized tag",
        6 => "bad processing instruction or declaration",
        7 => "bad comment",
        8 => "bad CDATA section",
        9 => "bad document type declaration",
        10 => "bad character data",
        11 => "bad start element tag",
        12 => "bad attribute",
        13 => "bad end element tag",
        14 => "start and end tags do not match",
        15 => "this node cannot sit at the document root",
        16 => "document has no element",
        17 => "more than one root element",
        _ => "malformed document",
    }
}

// Where an error happened, as a phrase. A UTF-16 or UTF-32 input is
// transcoded to UTF-8 before parsing, so pugixml's offsets index that
// internal buffer and cannot be mapped back to the caller's bytes; those
// documents say so instead of quoting a number that means nothing.
fn error_place(position: int, exact: bool) -> string {
    if exact { return "at byte {position}" }
    return "at an unknown byte offset (the input was transcoded from UTF-16 or UTF-32)"
}

fn parse_address(address: int, length: int, flags: int,
                 move buffer: Option<Bytes>) -> Result<Document> {
    var status: int = 0
    var doc_handle: int = 0
    var root: int = 0
    var code: int = 0
    var position: int = 0
    var exact: bool = true
    unsafe {
        let view: RawPtr<u64> = RawPtr.alloc(7)
        let source: RawPtr<u8> = RawPtr.from_address(address as u64)
        view.write(length as u64)
        view.offset(1).write(flags as u64)
        status = beans_enc_xml_parse(source, view)
        doc_handle = view.offset(2).read() as int
        root = view.offset(3).read() as int
        code = view.offset(4).read() as int
        position = view.offset(5).read() as int
        exact = view.offset(6).read() != 0
        view.free()
    }
    if status == 6 {
        return err("XML DOCTYPE {error_place(position, exact)} is rejected by default; opt in with Options.allow_doctype", "doctype")
    }
    if status != 0 {
        if code == 3 {
            return err("invalid XML {error_place(position, exact)}: out of memory", "memory")
        }
        return err("invalid XML {error_place(position, exact)}: {parse_phrase(code)}", "invalid")
    }
    return ok(new Document(new DocOwner(doc_handle, move buffer), root))
}

fn parse_data(data: Bytes, options: Options) -> Result<Document> {
    let borrowed: int = enc_bytes_address(data)
    if borrowed != 0 {
        return parse_address(
            borrowed, data.len(), options.flag_bits(), none)
    }
    let block: int = raw_from_bytes(data)
    let result: Result<Document> = parse_address(
        block, data.len(), options.flag_bits(), none)
    free_raw(block)
    return result
}

fn parse_owned_data(move data: Bytes,
                    options: Options) -> Result<Document> {
    let borrowed: int = enc_bytes_address(data)
    if borrowed == 0 {
        return parse_data(data, options)
    }
    return parse_address(
        borrowed, data.len(), options.flag_bits() | 4, some(move data))
}

fn parse_text(text: string, options: Options) -> Result<Document> {
    let borrowed: int = enc_string_address(text)
    if borrowed != 0 {
        return parse_address(
            borrowed, text.len(), options.flag_bits(), none)
    }
    return parse_data(Bytes.from(text), options)
}

/// Parses one XML document. DOCTYPE is rejected by default; external
/// entities are never fetched by design.
pub fn parse(text: string) -> Result<Document> {
    return parse_text(text, new Options())
}

/// Like `parse`, for binary buffers. A UTF-8/UTF-16/UTF-32 byte-order mark
/// is honoured; without one the bytes are read as UTF-8.
pub fn parse_bytes(data: Bytes) -> Result<Document> {
    return parse_data(data, new Options())
}

/// Consumes and parses a mutable byte buffer in place. The returned document
/// owns that buffer for as long as any Document or Node view still uses it.
pub fn parse_bytes_in_place(move data: Bytes) -> Result<Document> {
    return parse_owned_data(move data, new Options())
}

pub fn parse_with_options(text: string, options: Options) -> Result<Document> {
    return parse_text(text, options)
}

pub fn parse_bytes_with_options(data: Bytes, options: Options) -> Result<Document> {
    return parse_data(data, options)
}

/// Decodes one XML document into the type inferred from the result.
/// The compiler replaces this body after validating the concrete type.
pub fn decode<T>(text: string) -> Result<T> {
    return err("typed XML decoding was not lowered", "unsupported")
}

/// Like `decode`, for a borrowed XML byte buffer.
pub fn decode_bytes<T>(data: Bytes) -> Result<T> {
    return err("typed XML decoding was not lowered", "unsupported")
}

/// Consumes and parses a byte buffer in place while building the final typed
/// result. The temporary pugixml document is gone before this call returns.
pub fn decode_bytes_in_place<T>(move data: Bytes) -> Result<T> {
    return err("typed XML decoding was not lowered", "unsupported")
}

/// Typed decoding with the normal XML parser options.
pub fn decode_with_options<T>(text: string, options: Options) -> Result<T> {
    return err("typed XML decoding was not lowered", "unsupported")
}

fn write_document(document: Document, mode: int, indent: string) -> Result<string> {
    if indent.len() > 16 {
        return err("pretty indent is longer than 16 bytes", "invalid")
    }
    let borrowed_indent: int = enc_string_address(indent)
    let indent_bytes: Bytes = if borrowed_indent == 0 {
        Bytes.from(indent)
    } else { new Bytes(0) }
    let indent_block: int = if borrowed_indent == 0 {
        raw_from_bytes(indent_bytes)
    } else { borrowed_indent }
    var status: int = 0
    var buffer: int = 0
    var length: int = 0
    unsafe {
        let indent_view: RawPtr<u8> = RawPtr.from_address(indent_block as u64)
        let req: RawPtr<u64> = RawPtr.alloc(5)
        req.write(document.owner.handle as u64)
        req.offset(1).write(mode as u64)
        req.offset(2).write(indent.len() as u64)
        status = beans_enc_xml_write(indent_view, req)
        buffer = req.offset(3).read() as int
        length = req.offset(4).read() as int
        req.free()
    }
    if borrowed_indent == 0 { free_raw(indent_block) }
    if status != 0 {
        return err("cannot write this document", "invalid")
    }
    if length == 0 { return ok("") }
    let direct: string = enc_string_uninit(length)
    let direct_address: int = enc_string_address(direct)
    if direct_address != 0 {
        unsafe {
            let target: RawPtr<u8> =
                RawPtr.from_address(direct_address as u64)
            beans_enc_xml_take_buf(buffer, length, target)
        }
        return ok(direct)
    }
    let block: int = alloc_words((length + 7) / 8)
    unsafe {
        let view: RawPtr<u8> = RawPtr.from_address(block as u64)
        beans_enc_xml_take_buf(buffer, length, view)
    }
    let text: string = bytes_from_raw(block, length).to_string()
    free_raw(block)
    return ok(text)
}

/// Compact output: no added indentation or newlines, content untouched.
pub fn stringify(document: Document) -> Result<string> {
    return write_document(document, 0, "")
}

/// Indented output using `indent` (up to 16 bytes) per depth level.
pub fn stringify_pretty(document: Document, indent: string) -> Result<string> {
    return write_document(document, 1, indent)
}

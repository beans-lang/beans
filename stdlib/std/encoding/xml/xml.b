// XML over the vendored pugixml bridge (runtime/encoding).
//
// This is a DOM API, not a streaming one: parse materializes the whole
// document and Nodes are views into it. A Node keeps its document alive
// through a shared owner object, so a child stays valid after the local
// variable holding its root is gone.
//
// Names are qualified names. `prefix()` and `local_name()` split the
// qualified name at its colon; there is no namespace-URI resolution — this
// package does not pretend to match prefixes to xmlns declarations.
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
extern "C" fn beans_enc_xml_append_node(name: RawPtr<u8>, value: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_enc_xml_set_attr(name: RawPtr<u8>, value: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_enc_xml_write(indent: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_enc_xml_take_buf(buf: int, len: int, target: RawPtr<u8>) -> int

// ---- raw-buffer marshalling (word-at-a-time, no per-byte Beans calls) ----

fn raw_from_bytes(data: Bytes) -> int {
    let count: int = data.len()
    let words: int = (count + 7) / 8
    var address: int = 0
    unsafe {
        let block: RawPtr<u64> = RawPtr.alloc(if words == 0 { 1 } else { words })
        let whole: int = count / 8
        for index: int in 0..whole {
            block.offset(index).write(data.get_u64(index * 8) as u64)
        }
        let tail: RawPtr<u8> = RawPtr.from_address(block.address())
        for index: int in (whole * 8)..count {
            tail.offset(index).write(data.get(index) as u8)
        }
        address = block.address() as int
    }
    return address
}

fn bytes_from_raw(address: int, count: int) -> Bytes {
    var out: Bytes = new Bytes(count)
    unsafe {
        let block: RawPtr<u64> = RawPtr.from_address(address as u64)
        let whole: int = count / 8
        for index: int in 0..whole {
            out.put_u64(index * 8, block.offset(index).read() as int)
        }
        let tail: RawPtr<u8> = RawPtr.from_address(address as u64)
        for index: int in (whole * 8)..count {
            out.set(index, tail.offset(index).read() as int)
        }
    }
    return out
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

    fn init(handle: int) {
        self.handle = handle
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
    let block: int = alloc_words((length + 7) / 8)
    unsafe {
        let view: RawPtr<u8> = RawPtr.from_address(block as u64)
        beans_enc_xml_name_copy(handle, view)
    }
    let text: string = bytes_from_raw(block, length).to_string_full()
    free_raw(block)
    return text
}

fn node_value(handle: int) -> string {
    var length: int = 0
    unsafe {
        length = beans_enc_xml_value_len(handle)
    }
    if length == 0 { return "" }
    let block: int = alloc_words((length + 7) / 8)
    unsafe {
        let view: RawPtr<u8> = RawPtr.from_address(block as u64)
        beans_enc_xml_value_copy(handle, view)
    }
    let text: string = bytes_from_raw(block, length).to_string_full()
    free_raw(block)
    return text
}

// Appends one node under `parent` (0 = document top level) and wraps it.
fn append_under(owner: DocOwner, parent: int, kind: int,
                name: string, value: string) -> Result<Node> {
    let name_bytes: Bytes = Bytes.from(name)
    let value_bytes: Bytes = Bytes.from(value)
    let name_block: int = raw_from_bytes(name_bytes)
    let value_block: int = raw_from_bytes(value_bytes)
    var status: int = 0
    var handle: int = 0
    unsafe {
        let name_view: RawPtr<u8> = RawPtr.from_address(name_block as u64)
        let value_view: RawPtr<u8> = RawPtr.from_address(value_block as u64)
        let req: RawPtr<u64> = RawPtr.alloc(6)
        req.write(owner.handle as u64)
        req.offset(1).write(parent as u64)
        req.offset(2).write(kind as u64)
        req.offset(3).write(name_bytes.len() as u64)
        req.offset(4).write(value_bytes.len() as u64)
        status = beans_enc_xml_append_node(name_view, value_view, req)
        handle = req.offset(5).read() as int
        req.free()
    }
    free_raw(name_block)
    free_raw(value_block)
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
        var words: int = 0
        unsafe {
            words = beans_enc_xml_attrs_words(self.handle)
        }
        var found: List<Attribute> = []
        if words == 0 { return move found }
        let block: int = alloc_words(words)
        unsafe {
            let view: RawPtr<u64> = RawPtr.from_address(block as u64)
            beans_enc_xml_attrs_pack(self.handle, view)
            var cursor: int = 0
            for cursor < words {
                let name_len: int = view.offset(cursor).read() as int
                cursor += 1
                let name_text: string =
                    packed_text(view, cursor, name_len)
                cursor += (name_len + 7) / 8
                let value_len: int = view.offset(cursor).read() as int
                cursor += 1
                let value_text: string =
                    packed_text(view, cursor, value_len)
                cursor += (value_len + 7) / 8
                found.push(Attribute { name: name_text, value: value_text })
            }
        }
        free_raw(block)
        return move found
    }

    /// First attribute with this qualified name, or none.
    pub fn attribute(name: string) -> Option<string> {
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

    pub fn append_instruction(name: string, value: string) -> Result<Node> {
        return append_under(self.owner, self.handle, 5, name, value)
    }

    /// Adds one attribute. A duplicate qualified name on the same element is
    /// refused: parsed documents may carry duplicates (reported in order by
    /// `attributes()`), but building one on purpose is almost always a bug.
    pub fn set_attr(name: string, value: string) -> Result<bool> {
        match self.attribute(name) {
            some(_) => {
                return err("attribute {name} is already set on this element", "exists")
            }
            none => {}
        }
        let name_bytes: Bytes = Bytes.from(name)
        let value_bytes: Bytes = Bytes.from(value)
        let name_block: int = raw_from_bytes(name_bytes)
        let value_block: int = raw_from_bytes(value_bytes)
        var status: int = 0
        unsafe {
            let name_view: RawPtr<u8> = RawPtr.from_address(name_block as u64)
            let value_view: RawPtr<u8> = RawPtr.from_address(value_block as u64)
            let req: RawPtr<u64> = RawPtr.alloc(3)
            req.write(self.handle as u64)
            req.offset(1).write(name_bytes.len() as u64)
            req.offset(2).write(value_bytes.len() as u64)
            status = beans_enc_xml_set_attr(name_view, value_view, req)
            req.free()
        }
        free_raw(name_block)
        free_raw(value_block)
        if status != 0 {
            return err("cannot set attribute {name} here", "invalid")
        }
        return ok(true)
    }
}

// Reads `len` bytes starting at word `cursor` of a packed stream.
fn packed_text(view: RawPtr<u64>, cursor: int, len: int) -> string {
    var data: Bytes = new Bytes(len)
    unsafe {
        let whole: int = len / 8
        for index: int in 0..whole {
            data.put_u64(index * 8, view.offset(cursor + index).read() as int)
        }
        if whole * 8 < len {
            let last: u64 = view.offset(cursor + whole).read()
            for index: int in (whole * 8)..len {
                let shift: int = (index - whole * 8) * 8
                data.set(index, ((last >> (shift as u64)) & 0xff) as int)
            }
        }
    }
    return data.to_string_full()
}

/// A whole XML document. Parse one, or build one from `new_document()`.
pub class Document {
    owner: DocOwner
    root_handle: int

    fn init(owner: DocOwner, root_handle: int) {
        self.owner = owner
        self.root_handle = root_handle
    }

    /// An empty document to build into.
    pub static fn new_document() -> Document {
        var handle: int = 0
        unsafe {
            handle = beans_enc_xml_new_doc()
        }
        var root: int = 0
        unsafe {
            root = beans_enc_xml_doc_root(handle)
        }
        return new Document(new DocOwner(handle), root)
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

    pub fn append_instruction(name: string, value: string) -> Result<Node> {
        return append_under(self.owner, 0, 5, name, value)
    }

    /// Adds `<?xml version="..." encoding="..."?>`. Pass "" to omit the
    /// encoding attribute.
    pub fn append_declaration(version: string, encoding: string) -> Result<Node> {
        let node: Node = append_under(self.owner, 0, 6, "", "")?
        node.set_attr("version", version)?
        if encoding != "" {
            node.set_attr("encoding", encoding)?
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

fn parse_data(data: Bytes, options: Options) -> Result<Document> {
    let block: int = raw_from_bytes(data)
    var status: int = 0
    var doc_handle: int = 0
    var root: int = 0
    var code: int = 0
    var position: int = 0
    unsafe {
        let view: RawPtr<u8> = RawPtr.from_address(block as u64)
        let req: RawPtr<u64> = RawPtr.alloc(6)
        req.write(data.len() as u64)
        req.offset(1).write(options.flag_bits() as u64)
        status = beans_enc_xml_parse(view, req)
        doc_handle = req.offset(2).read() as int
        root = req.offset(3).read() as int
        code = req.offset(4).read() as int
        position = req.offset(5).read() as int
        req.free()
    }
    free_raw(block)
    if status == 6 {
        return err("XML DOCTYPE at byte {position} is rejected by default; opt in with Options.allow_doctype", "doctype")
    }
    if status != 0 {
        if code == 3 {
            return err("invalid XML at byte {position}: out of memory", "memory")
        }
        return err("invalid XML at byte {position}: {parse_phrase(code)}", "invalid")
    }
    return ok(new Document(new DocOwner(doc_handle), root))
}

/// Parses one XML document. DOCTYPE is rejected by default; external
/// entities are never fetched by design.
pub fn parse(text: string) -> Result<Document> {
    return parse_data(Bytes.from(text), new Options())
}

/// Like `parse`, for binary buffers. A UTF-8/UTF-16/UTF-32 byte-order mark
/// is honoured; without one the bytes are read as UTF-8.
pub fn parse_bytes(data: Bytes) -> Result<Document> {
    return parse_data(data, new Options())
}

pub fn parse_with(text: string, options: Options) -> Result<Document> {
    return parse_data(Bytes.from(text), options)
}

pub fn parse_bytes_with(data: Bytes, options: Options) -> Result<Document> {
    return parse_data(data, options)
}

fn write_document(document: Document, mode: int, indent: string) -> Result<string> {
    let indent_bytes: Bytes = Bytes.from(indent)
    if indent_bytes.len() > 16 {
        return err("pretty indent is longer than 16 bytes", "invalid")
    }
    let indent_block: int = raw_from_bytes(indent_bytes)
    var status: int = 0
    var buffer: int = 0
    var length: int = 0
    unsafe {
        let indent_view: RawPtr<u8> = RawPtr.from_address(indent_block as u64)
        let req: RawPtr<u64> = RawPtr.alloc(5)
        req.write(document.owner.handle as u64)
        req.offset(1).write(mode as u64)
        req.offset(2).write(indent_bytes.len() as u64)
        status = beans_enc_xml_write(indent_view, req)
        buffer = req.offset(3).read() as int
        length = req.offset(4).read() as int
        req.free()
    }
    free_raw(indent_block)
    if status != 0 {
        return err("cannot write this document", "invalid")
    }
    let block: int = alloc_words((length + 7) / 8)
    unsafe {
        let view: RawPtr<u8> = RawPtr.from_address(block as u64)
        beans_enc_xml_take_buf(buffer, length, view)
    }
    let text: string = bytes_from_raw(block, length).to_string_full()
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
